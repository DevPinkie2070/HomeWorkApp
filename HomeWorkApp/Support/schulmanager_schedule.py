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
import uuid
from datetime import date, datetime, timedelta
from pathlib import Path

from selenium import webdriver
from selenium.webdriver.chrome.options import Options
from selenium.webdriver.common.by import By
from selenium.webdriver.support import expected_conditions as EC
from selenium.webdriver.support.ui import WebDriverWait


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


def fail(error: str) -> None:
    print(json.dumps({"error": error}))
    raise SystemExit(0)


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
                week = schedules.getPlan(0, driver, ALL=True, startDate=f"?start={monday.isoformat()}")
                for weekday, lessons in enumerate(week):
                    lesson_date = monday + timedelta(days=weekday)
                    if lesson_date < reference_date:
                        continue
                    for lesson in lessons:
                        if lesson and matches(lesson, request["subject"]):
                            print(json.dumps({"date": lesson_date.isoformat(), "subject": request["subject"]}, ensure_ascii=False))
                            return
            fail("no_next_lesson")
        finally:
            driver.quit()
            shutil.rmtree(profile_path, ignore_errors=True)
    except SystemExit:
        raise
    except Exception as error:
        # Return only the exception type; Selenium errors may contain page data.
        fail(f"request_failed:{type(error).__name__}")


if __name__ == "__main__":
    main()
