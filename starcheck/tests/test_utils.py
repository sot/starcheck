import pickle

from sparkles.messages import Message

from starcheck import utils
from starcheck.utils import (
    check_hot_pix,
    collect_proseco_catalog,
    format_sparkles_message,
    get_proseco_catalog,
    get_starcheck_index,
    run_sparkles_jupiter_checks,
    save_proseco_catalogs,
)

# Real proseco_args from obsid 28777 in JUN2325_A (HRC-I, 3 fids, 8 acq/5 guide)
OBS_28777_ARGS = {
    "obsid": 28777,
    "att": [0.142378962865, -0.842210948602, 0.4728311264, 0.216424755738],
    "date": "2025:174:00:42:44.586",
    "detector": "HRC-I",
    "dither_acq": [20.0014963044938, 20.0014963044938],
    "dither_guide": [20.0014963044938, 20.0014963044938],
    "fid_ids": [8, 9, 10],
    "include_halfws_acq": [160, 160, 120, 140, 100, 160, 160, 100],
    "include_ids_acq": [
        331222504,
        331224640,
        260576048,
        331223656,
        260571904,
        260580432,
        260575280,
        260575376,
    ],
    "include_ids_guide": [331222504, 331224640, 260576048, 331223656, 260571904],
    "man_angle": 122.221322321489,
    "n_acq": 8,
    "n_fid": 3,
    "n_guide": 5,
    "sim_offset": 0,
    "t_ccd_acq": -4.72435604571444,
    "t_ccd_guide": -4.53268231435102,
    "duration": 20000.0,
    "target_name": "SN 1941C",
}

# Attitude and date of the obsid 29674 Jupiter observation in SEP1525A, with the
# star and fid selection left to proseco.
OBS_29674_ARGS = {
    "obsid": 29674,
    "att": [0.47935711, 0.44950136, 0.68474659, 0.31509901],
    "date": "2025:258:14:42:16.000",
    "detector": "HRC-S",
    "dither_acq": [20.0, 20.0],
    "dither_guide": [20.0, 20.0],
    "fid_ids": [],
    "include_halfws_acq": [],
    "include_ids_acq": [],
    "include_ids_guide": [],
    "man_angle": 180.0,
    "n_acq": 8,
    "n_guide": 5,
    "sim_offset": 0,
    "t_ccd_acq": -8.6,
    "t_ccd_guide": -8.6,
    "duration": 10000.0,
    "target_name": "Jupiter",
}

RAN_PARTIAL_CHECKS = "Jupiter mag <= -2.0. Ran Partial OBO Mitigation checks."


def test_get_proseco_catalog_returns_expected_acq_stars():
    """get_proseco_catalog returns a catalog containing all commanded acq star IDs."""
    aca = get_proseco_catalog(**OBS_28777_ARGS)
    acq_ids = set(aca.acqs["id"])
    for star_id in OBS_28777_ARGS["include_ids_acq"]:
        assert star_id in acq_ids


def test_get_proseco_catalog_translates_fid_ids():
    """Starcheck HRC-I fid ids 8-10 become proseco per-detector fid ids 2-4."""
    aca = get_proseco_catalog(**OBS_28777_ARGS)
    assert sorted(aca.fids["id"]) == [2, 3, 4]


def test_run_sparkles_jupiter_checks_no_jupiter(monkeypatch):
    """A target without "jupiter" in the name gives no messages and builds no catalog."""

    def fail_get_proseco_catalog(**kwargs):
        raise AssertionError("get_proseco_catalog should not be called")

    monkeypatch.setattr(utils, "get_proseco_catalog", fail_get_proseco_catalog)
    result = run_sparkles_jupiter_checks(OBS_28777_ARGS)
    assert result == {"warn": [], "orange_warn": [], "yellow_warn": [], "fyi": []}


def test_run_sparkles_jupiter_checks_jupiter_target():
    """A Jupiter target in a partial mitigation period runs the Jupiter checks."""
    result = run_sparkles_jupiter_checks(OBS_29674_ARGS)
    assert RAN_PARTIAL_CHECKS in result["fyi"]


def test_run_sparkles_jupiter_checks_no_target_name():
    """A missing target name (None from Perl undef) does not raise."""
    args = OBS_28777_ARGS | {"target_name": None}
    result = run_sparkles_jupiter_checks(args)
    assert result == {"warn": [], "orange_warn": [], "yellow_warn": [], "fyi": []}


def test_run_sparkles_jupiter_checks_proseco_failure():
    """If proseco cannot build the catalog, report a caution instead of raising."""
    args = OBS_28777_ARGS | {
        "target_name": "Jupiter",
        "include_ids_acq": [1],
        "include_halfws_acq": [160],
    }
    result = run_sparkles_jupiter_checks(args)
    assert result["warn"] == []
    assert result["yellow_warn"] == []
    assert result["fyi"] == []
    assert len(result["orange_warn"]) == 1
    assert result["orange_warn"][0].startswith(
        "Jupiter checks not run: proseco could not build a catalog"
    )


def _starcheck_catalog_ids_28777() -> list[int | None]:
    """Starcheck catalog ids by index for a made-up ordering of the 28777 catalog.

    Starcheck index 3 is HRC-I fid 8 (proseco fid 2) and index 10 is star 331222504.
    The other slots are empty.
    """
    catalog_ids = [None] * 16
    catalog_ids[2] = 8
    catalog_ids[9] = 331222504
    return catalog_ids


def test_get_starcheck_index():
    """Proseco catalog entries map to starcheck catalog indexes by id."""
    acar = get_proseco_catalog(**OBS_28777_ARGS).get_review_table()
    catalog_ids = _starcheck_catalog_ids_28777()
    fid_idx = acar["idx"][(acar["type"] == "FID") & (acar["id"] == 2)][0]
    star_idx = acar["idx"][acar["id"] == 331222504][0]
    other_idx = acar["idx"][acar["id"] == 331224640][0]

    assert get_starcheck_index(acar, fid_idx, "HRC-I", catalog_ids) == 3
    assert get_starcheck_index(acar, star_idx, "HRC-I", catalog_ids) == 10
    # In the proseco catalog but not the starcheck one, or not in either
    assert get_starcheck_index(acar, other_idx, "HRC-I", catalog_ids) is None
    assert get_starcheck_index(acar, 99, "HRC-I", catalog_ids) is None


def test_format_sparkles_message():
    """The starcheck index replaces the proseco idx in a sparkles message."""
    acar = get_proseco_catalog(**OBS_28777_ARGS).get_review_table()
    catalog_ids = _starcheck_catalog_ids_28777()
    star_idx = int(acar["idx"][acar["id"] == 331222504][0])
    msg = Message(
        "critical",
        f"Jupiter column in acquisition box idx {star_idx} id 331222504 row 1.0 col 2.0",
        idx=star_idx,
    )
    text = format_sparkles_message(msg, acar, "HRC-I", catalog_ids)
    assert text == "[10] Jupiter column in acquisition box id 331222504 row 1.0 col 2.0"

    # Messages without an idx are unchanged
    info = Message("info", "Jupiter mag <= -2.0. Ran Partial OBO Mitigation checks.")
    assert format_sparkles_message(info, acar, "HRC-I", catalog_ids) == info.text


def test_save_proseco_catalogs(tmp_path):
    """Collected catalogs for all obsids, not just Jupiter ones, are saved by obsid."""
    utils.PROSECO_CATALOGS.clear()
    collect_proseco_catalog(OBS_28777_ARGS)
    collect_proseco_catalog(OBS_29674_ARGS)
    out_path = tmp_path / "catalogs.pkl"
    save_proseco_catalogs(out_path)
    with open(out_path, "rb") as fh:
        catalogs = pickle.load(fh)
    assert sorted(catalogs) == [28777, 29674]
    assert set(OBS_28777_ARGS["include_ids_acq"]) <= set(catalogs[28777].acqs["id"])
    utils.PROSECO_CATALOGS.clear()


def test_run_sparkles_jupiter_checks_reuses_collected_catalog(monkeypatch):
    """The Jupiter checks reuse a catalog already collected for -save_pkl."""
    utils.PROSECO_CATALOGS.clear()
    collect_proseco_catalog(OBS_29674_ARGS)

    def fail_get_proseco_catalog(**kwargs):
        raise AssertionError("get_proseco_catalog should not be called again")

    monkeypatch.setattr(utils, "get_proseco_catalog", fail_get_proseco_catalog)
    result = run_sparkles_jupiter_checks(OBS_29674_ARGS)
    assert RAN_PARTIAL_CHECKS in result["fyi"]
    utils.PROSECO_CATALOGS.clear()


def test_check_dynamic_hot_pix():
    # Parameters of obsid 25274 from JUL0323A
    idxs = [1, 2, 3, 4, 5, 6, 7, 8]
    yags = [
        -773.135672595873,
        2140.37683262341,
        -1826.2356726102,
        -1380.0856717436,
        -713.835673125859,
        -1322.09192254126,
        -2185.44191819395,
        101.314326039055,
    ]
    zags = [
        -1741.99192158156,
        166.726825875404,
        160.264325897248,
        -2469.16691506774,
        -436.641923465157,
        -1728.21692250903,
        -1033.99192330043,
        1259.22057376853,
    ]
    mags = [7, 7, 7, 8.217, 9.052, 9.75, 10.407, 10.503]
    types = ["FID", "FID", "FID", "BOT", "BOT", "BOT", "BOT", "BOT"]
    t_ccd = -11.2132562902057
    dither_y = 7.9989482672109
    dither_z = 7.9989482672109

    # Use a date before the PEA patch uplink
    date = "2023:138"

    imposters1 = check_hot_pix(
        idxs, yags, zags, mags, types, t_ccd, date, dither_y, dither_z
    )

    # Use a date after the PEA patch uplink
    date = "2023:140"
    imposters2 = check_hot_pix(
        idxs, yags, zags, mags, types, t_ccd, date, dither_y, dither_z
    )

    # These stars are in mag-sorted order so the bonus should be applied to the last two
    # Stars with idx 7 and 8 should have bonus-applied t_ccd
    dyn_bgd_dt_ccd = 4.0

    # The imposters should be the same except for t_ccd, offset, mag
    # as these dates were selected to have matching dark cal files
    for imposter1, imposter2 in zip(imposters1, imposters2, strict=False):
        assert imposter1["dark_date"] == imposter2["dark_date"]
        assert imposter1["idx"] == imposter2["idx"]
        assert imposter1["bad2_row"] == imposter2["bad2_row"]
        assert imposter1["bad2_col"] == imposter2["bad2_col"]
        assert imposter1["t_ccd"] == t_ccd
        assert imposter1["status"] == 0
        assert imposter2["status"] == 0
        if imposter1["idx"] < 7:
            assert imposter2["t_ccd"] == imposter1["t_ccd"]
            assert imposter1["bad2_mag"] == imposter2["bad2_mag"]
            assert imposter1["offset"] == imposter2["offset"]
        else:
            assert imposter2["t_ccd"] == imposter1["t_ccd"] - dyn_bgd_dt_ccd
            assert imposter1["bad2_mag"] < imposter2["bad2_mag"]
            assert imposter1["offset"] > imposter2["offset"]
