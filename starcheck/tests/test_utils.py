import pytest
import numpy as np
from starcheck.utils import check_hot_pix
from starcheck.utils import _get_fid_offset


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
    for imposter1, imposter2 in zip(imposters1, imposters2):
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


def test_get_fid_offset(monkeypatch):
    # Test case 1: enable_fid_offset_env is True
    with monkeypatch.context() as m:
        m.setenv("PROSECO_ENABLE_FID_OFFSET", "True")
        date = "2023:200"
        t_ccd_acq = -5.0
        expected_dy = -0.36
        expected_dz = -5.81
        dy, dz = _get_fid_offset(date, t_ccd_acq)
        assert np.isclose(dy, expected_dy, atol=0.1, rtol=0)
        assert np.isclose(dz, expected_dz, atol=0.1, rtol=0)

    # Test case 2: enable_fid_offset_env is False
    with monkeypatch.context() as m:
        m.setenv("PROSECO_ENABLE_FID_OFFSET", "False")
        date = "2023:200"
        t_ccd_acq = -5.0
        expected_dy = 0.0
        expected_dz = 0.0
        dy, dz = _get_fid_offset(date, t_ccd_acq)
        assert dy == expected_dy
        assert dz == expected_dz

    # Test case 3: enable_fid_offset_env is invalid
    with monkeypatch.context() as m:
        m.setenv("PROSECO_ENABLE_FID_OFFSET", "invalid")
        date = "2023:200"
        t_ccd_acq = -5.0
        with pytest.raises(ValueError) as e:
            _get_fid_offset(date, t_ccd_acq)
        assert (
            str(e.value)
            == 'PROSECO_ENABLE_FID_OFFSET env var must be either "True" or "False" got invalid'
        )
