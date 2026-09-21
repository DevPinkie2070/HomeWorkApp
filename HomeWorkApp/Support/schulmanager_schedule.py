#!/usr/bin/env python3
"""Read the next matching lesson through SchmueI/Schulmanager-API.

The Swift app sends one JSON object on stdin. Credentials are never written to
disk or emitted on stdout/stderr by this bridge.
"""

from __future__ import annotations

import html
import json
import os
import re
import shutil
import sys
import tempfile
import traceback
import uuid
from datetime import date, datetime, timedelta
from pathlib import Path

def _locate(error: BaseException) -> str:
    # The deepest frame alone hasn't been enough to pin down where an error actually originates
    # (e.g. a bad-argument TypeError's deepest frame is the *caller*, not the library code that
    # rejected the call) - report the whole call chain instead, innermost first. Still just
    # file:line pairs, no source text or local values, so nothing sensitive leaks.
    frames = traceback.extract_tb(error.__traceback__)
    if not frames:
        return ""
    chain = "<-".join(f"{Path(frame.filename).name}:{frame.lineno}" for frame in reversed(frames))
    return f"@{chain}"


try:
    from selenium import webdriver
    from selenium.webdriver.chrome.options import Options
    from selenium.webdriver.common.by import By
    from selenium.webdriver.support import expected_conditions as EC
    from selenium.webdriver.support.ui import WebDriverWait
except Exception as error:  # pragma: no cover - only when the Selenium runtime is broken/missing
    print(json.dumps({"error": f"request_failed:{type(error).__name__}{_locate(error)}"}))
    raise SystemExit(0)


def normalise(value: str) -> str:
    return re.sub(r"\s+", " ", html.unescape(re.sub(r"<[^>]+>", " ", value))).strip().casefold()


def compact(value: str) -> str:
    return re.sub(r"[^a-z0-9]+", "", normalise(value))


def matches(lesson: str, requested: str) -> bool:
    lesson_name = normalise(lesson)
    subject_name = normalise(requested)
    return (
        subject_name in lesson_name
        or lesson_name in subject_name
        or compact(subject_name) in compact(lesson_name)
        or compact(lesson_name) in compact(subject_name)
    )


def collect_schedule_fallback(driver: webdriver.Chrome) -> list[list[str]]:
    """Read timetable cells without relying on the vendor parser's fixed indexes."""
    WebDriverWait(driver, 20).until(
        EC.presence_of_element_located((By.TAG_NAME, "table"))
    )
    tables = driver.find_elements(By.TAG_NAME, "table")
    if not tables:
        return [[] for _ in range(7)]

    week = [[] for _ in range(7)]
    rows = tables[0].find_elements(By.TAG_NAME, "tr")
    for row in rows[2:]:
        cells = row.find_elements(By.TAG_NAME, "td")
        for day in range(7):
            cell_index = day + 1
            value = cells[cell_index].text.strip() if cell_index < len(cells) else ""
            week[day].append(re.sub(r"\s+", " ", value))
    return week


def fail(error: str) -> None:
    print(json.dumps({"error": error}))
    raise SystemExit(0)


def normalise_week(week: object) -> list[list[str]]:
    """Coerces whatever the vendor parser (or our own fallback) returned into a guaranteed
    7-entry list of string lists. The vendor's getPlan() has been observed to represent a day
    with no lessons as None rather than [], which crashes any/enumerate/iteration downstream
    with a bare TypeError if not normalised first."""
    if not isinstance(week, list):
        return [[] for _ in range(7)]
    normalised: list[list[str]] = []
    for day in range(7):
        day_value = week[day] if day < len(week) else None
        if isinstance(day_value, list):
            normalised.append(["" if cell is None else str(cell) for cell in day_value])
        else:
            normalised.append([])
    return normalised


def login_with_email(driver: webdriver.Chrome, email: str, password: str) -> str:
    driver.get("https://login.schulmanager-online.de/#/login")
    wait = WebDriverWait(driver, 30)
    email_field = wait.until(EC.presence_of_element_located((By.ID, "emailOrUsername")))
    password_field = wait.until(EC.presence_of_element_located((By.ID, "password")))
    email_field.send_keys(email)
    password_field.send_keys(password)
    driver.find_element(
        By.XPATH,
        "//button[normalize-space()='Einloggen']"
    ).click()

    try:
        wait.until(lambda current_driver: (
            "#/login" not in current_driver.current_url
            or bool(current_driver.find_elements(By.ID, "accountDropdown"))
            or not bool(current_driver.find_elements(By.ID, "emailOrUsername"))
            or "E-Mail-Adresse oder Passwort sind falsch." in current_driver.find_element(By.TAG_NAME, "body").text
        ))
        if "E-Mail-Adresse oder Passwort sind falsch." in driver.find_element(By.TAG_NAME, "body").text:
            return "invalid_credentials"
        return "success"
    except Exception:
        return "login_timeout"


def main() -> None:
    try:
        request = json.load(sys.stdin)
        api_path = Path(os.environ["SCHULMANAGER_API_PATH"])
        if not (api_path / "main" / "schedules.py").is_file():
            fail("adapter_missing")

        sys.path.insert(0, str(api_path))
        from main import schedules

        reference_date = datetime.strptime(request["referenceDate"], "%Y-%m-%d").date()
        profile_path = Path(tempfile.mkdtemp(prefix=f"homeworkapp-{uuid.uuid4().hex}-"))
        options = Options()
        options.add_argument("--headless=new")
        options.add_argument("--window-size=1920,1080")
        options.add_argument("--disable-dev-shm-usage")
        options.add_argument("--disable-domain-reliability")
        options.add_argument(f"--user-data-dir={profile_path}")
        options.add_argument("user-agent=Schulmanager-API-PUBLIC-GIT-UNDEFINED")
        options.add_experimental_option("prefs", {
            "profile.managed_default_content_settings.images": 2,
            "profile.default_content_settings.popups": 0,
        })
        driver = webdriver.Chrome(options=options)
        try:
            login_result = login_with_email(driver, request["username"], request["password"])
            if login_result != "success":
                fail(f"login_{login_result}")

            first_monday = reference_date - timedelta(days=reference_date.weekday())
            for week_offset in range(2):
                monday = first_monday + timedelta(days=week_offset * 7)
                try:
                    week = schedules.getPlan(0, driver, ALL=True, startDate=f"?start={monday.isoformat()}")
                except IndexError:
                    week = collect_schedule_fallback(driver)
                week = normalise_week(week)
                if not any(week) or not any(cell.strip() for cell in week[reference_date.weekday()]):
                    week = normalise_week(collect_schedule_fallback(driver))
                for weekday, lessons in enumerate(week):
                    lesson_date = monday + timedelta(days=weekday)
                    if lesson_date < reference_date:
                        continue
                    if not request.get("subject") and lesson_date == reference_date:
                        entries = [
                            {"period": index + 1, "title": value, "date": lesson_date.isoformat()}
                            for index, value in enumerate(lessons) if value
                        ]
                        if not entries:
                            # A genuinely empty day is rare on a weekday; far more likely the
                            # vendor parser's selectors no longer match the current Schulmanager
                            # page layout. Report this distinctly so it isn't mistaken for bad
                            # credentials.
                            fail("schedule_empty")
                        print(json.dumps({"schedule": entries}, ensure_ascii=False))
                        return
                    for period, lesson in enumerate(lessons, start=1):
                        if lesson and request.get("subject") and matches(lesson, request["subject"]):
                            print(json.dumps({"date": lesson_date.isoformat(), "subject": request["subject"]}, ensure_ascii=False))
                            return
            fail("no_next_lesson")
        finally:
            # A crash here (e.g. Chrome already gone) would otherwise replace a result that was
            # already reported via fail()'s SystemExit with an unhandled exception, turning a
            # decodable error into a bare nonzero exit Swift can't make sense of.
            try:
                driver.quit()
            except Exception:
                pass
            shutil.rmtree(profile_path, ignore_errors=True)
    except SystemExit:
        raise
    except Exception as error:
        # Only the exception type plus where it happened (file:line, no source text or locals) -
        # Selenium errors may contain page data we don't want to forward, but a bare type name
        # alone hasn't been enough to pin down repeat failures.
        fail(f"request_failed:{type(error).__name__}{_locate(error)}")


if __name__ == "__main__":
    main()
