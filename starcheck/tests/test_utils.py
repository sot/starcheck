import pickle

import starcheck.utils as utils
from starcheck.utils import (
    check_hot_pix,
    get_and_collect_proseco_catalog,
    get_proseco_catalog,
    run_sparkles_planet_checks,
    save_proseco_catalogs,
)

# Real proseco_args from obsid 28777 in JUN2325_A (HRC-I, 3 fids, 8 acq/5 guide)
_OBS_28777_ARGS = {
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


def test_get_proseco_catalog_returns_expected_acq_stars():
    """get_proseco_catalog returns a catalog containing all commanded acq star IDs."""
    aca = get_proseco_catalog(**_OBS_28777_ARGS)
    acq_ids = set(aca.acqs["id"])
    for star_id in _OBS_28777_ARGS["include_ids_acq"]:
        assert star_id in acq_ids


def test_get_and_collect_proseco_catalog_accumulates():
    """get_and_collect_proseco_catalog stores the catalog in _proseco_catalogs keyed by obsid."""
    utils._proseco_catalogs.clear()
    aca = get_and_collect_proseco_catalog(_OBS_28777_ARGS)
    assert _OBS_28777_ARGS["obsid"] in utils._proseco_catalogs
    assert utils._proseco_catalogs[_OBS_28777_ARGS["obsid"]] is aca
    utils._proseco_catalogs.clear()


# Venus bad case adapted from sparkles test_venus_bad (att/date where Venus is on CCD)
_VENUS_BAD_ARGS = {
    "obsid": 18696,
    "att": [-0.54152552, 0.17005146, -0.10308105, 0.81682734],
    "man_angle": 90,
    "date": "2017:010:06:57:57.000",
    "t_ccd_acq": -10.0,
    "t_ccd_guide": -10.0,
    "dither_acq": [7.9992, 7.9992],
    "dither_guide": [7.9992, 7.9992],
    "detector": "ACIS-I",
    "sim_offset": 0,
    "n_acq": 8,
    "n_guide": 5,
    "n_fid": 3,
    "fid_ids": [1, 2, 3],
    "include_ids_acq": [],
    "include_halfws_acq": [],
    "include_ids_guide": [],
    "duration": 30000.0,
    "target_name": "Venus",
}


def test_run_sparkles_planet_checks_venus_bad():
    """run_sparkles_planet_checks produces critical warnings and sets planet_full_mitigation
    for an attitude where Venus is on the CCD and mitigation requirements are not met."""
    result = run_sparkles_planet_checks(_VENUS_BAD_ARGS)
    assert result["planet_full_mitigation"] is True
    assert "Need 5 guide stars on side of CCD opposite bright object." in result["warn"]
    assert "Need 2 fid lights on side of CCD opposite bright object." in result["warn"]
    assert "Bright object tracks too close to CCD boundary row=0." in result["warn"]
    assert "Full mitigation OBO checks failed." in result["warn"]
    assert "Venus on CCD. (mag -5.0 to -2.9)." in result["fyi"]
    assert result["orange_warn"] == []
    assert result["yellow_warn"] == []


def test_run_sparkles_planet_checks_no_planet():
    """run_sparkles_planet_checks returns no warnings and planet_full_mitigation False
    for a normal observation with no nearby bright planet."""
    result = run_sparkles_planet_checks(_OBS_28777_ARGS)
    assert result["planet_full_mitigation"] is False
    assert result["warn"] == []
    assert result["orange_warn"] == []
    assert result["yellow_warn"] == []


def test_save_proseco_catalogs(tmp_path):
    """save_proseco_catalogs writes _proseco_catalogs to a readable pickle file."""
    utils._proseco_catalogs.clear()
    get_and_collect_proseco_catalog(_OBS_28777_ARGS)
    out_path = tmp_path / "catalogs.pkl"
    save_proseco_catalogs(out_path)
    assert out_path.exists()
    with open(out_path, "rb") as f:
        loaded = pickle.load(f)
    assert _OBS_28777_ARGS["obsid"] in loaded
    utils._proseco_catalogs.clear()


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
