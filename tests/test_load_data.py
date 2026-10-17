from pathlib import Path

import pytest

from src.ingestion.load_data import CSV_TABLES, REQUIRED_FILES, validate_data_dir


def test_required_files_are_supported():
    assert REQUIRED_FILES.issubset(CSV_TABLES)
    assert "olist_orders_dataset.csv" in CSV_TABLES
    assert CSV_TABLES["olist_order_items_dataset.csv"] == "order_items"


def test_missing_directory_fails_with_actionable_message(tmp_path: Path):
    with pytest.raises(FileNotFoundError, match="CSV directory not found"):
        validate_data_dir(tmp_path / "missing")


def test_missing_required_csv_is_reported(tmp_path: Path):
    (tmp_path / "olist_orders_dataset.csv").write_text("order_id\n", encoding="utf-8")
    with pytest.raises(FileNotFoundError, match="Missing required Olist CSV files"):
        validate_data_dir(tmp_path)


def test_valid_dataset_returns_present_supported_files(tmp_path: Path):
    for filename in REQUIRED_FILES:
        (tmp_path / filename).write_text("id\n", encoding="utf-8")
    result = validate_data_dir(tmp_path)
    assert len(result) == len(REQUIRED_FILES)
    assert all(path.exists() for path in result)
