from starcheck.utils import check_hot_pix


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
    # There is no bonus or penalty applied so the temperatures should all be the same as the
    # input t_ccd
    for imposter in imposters1:
        assert imposter["status"] == 0
        assert imposter["t_ccd"] == t_ccd

    # Use a date after the PEA patch uplink
    date = "2023:140"
    imposters2 = check_hot_pix(
        idxs, yags, zags, mags, types, t_ccd, date, dither_y, dither_z
    )

    # These stars are in mag-sorted order so the bonus should be applied to the last two
    # Stars with idx 7 and 8 should have bonus-applied t_ccd
    dyn_bgd_dt_ccd = 4.0
    for imposter in imposters2:
        assert imposter["status"] == 0
        if imposter["idx"] < 7:
            assert imposter["t_ccd"] == t_ccd
        else:
            assert imposter["t_ccd"] == t_ccd - dyn_bgd_dt_ccd

    # The imposters should be the same except for t_ccd, offset, mag
    # as these dates were selected to have matching dark cal files
    for imposter1, imposter2 in zip(imposters1, imposters2):
        assert imposter1["dark_date"] == imposter2["dark_date"]
        assert imposter1["idx"] == imposter2["idx"]
        assert imposter1["bad2_row"] == imposter2["bad2_row"]
        assert imposter1["bad2_col"] == imposter2["bad2_col"]
        assert imposter1["bad2_mag"] <= imposter2["bad2_mag"]
        assert imposter1["status"] == imposter2["status"]
        assert imposter1["offset"] >= imposter2["offset"]
