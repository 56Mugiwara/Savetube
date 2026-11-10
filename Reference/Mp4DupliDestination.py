import os
import platform
import shutil
import time
from pathlib import Path

def get_downloads_folder() -> Path:
    return Path.home() / "Downloads"

def is_file_ready(file_path: Path) -> bool:
    if not file_path.exists():
        return False

    # Ignore files containing temp tags anywhere in the name
    ignored_keywords = [".temp", ".tmp", ".crdownload", ".part", ".download"]
    if any(keyword in file_path.name.lower() for keyword in ignored_keywords):
        return False

    try:
        if file_path.stat().st_size == 0:
            return False

        # Verify file size stability (stops copying while writing)
        initial_size = file_path.stat().st_size
        time.sleep(0.5)
        if file_path.stat().st_size != initial_size:
            return False

        with open(file_path, "rb") as f:
            f.read(1024)
        return True
    except (PermissionError, OSError):
        return False

def main():
    source_dir = Path(__file__).resolve().parent
    downloads_dir = get_downloads_folder()

    print(f"[{platform.system()}] Active directory monitor started...")
    processed_files = set()

    while True:
        try:
            for file_path in source_dir.glob("*"):
                filename_lower = file_path.name.lower()

                # Strictly check for valid extensions AND ensure no .temp in the name
                is_valid_media = (
                    file_path.is_file()
                    and (filename_lower.endswith(".mp4") or filename_lower.endswith(".mp3"))
                    and not any(temp_tag in filename_lower for temp_tag in [".temp", ".tmp", ".crdownload", ".part"])
                )

                if is_valid_media:
                    filename = file_path.name

                    if filename in processed_files:
                        continue

                    dest_path = downloads_dir / filename

                    if file_path.resolve() == dest_path.resolve():
                        processed_files.add(filename)
                        continue

                    if not is_file_ready(file_path):
                        continue

                    try:
                        shutil.copy2(file_path, dest_path)
                        print(f"SUCCESS: Copied finished file '{filename}' to Downloads.")
                        processed_files.add(filename)
                    except (PermissionError, OSError) as err:
                        pass

        except Exception as e:
            print(f"Error: {e}")

        time.sleep(1)

if __name__ == "__main__":
    main()
