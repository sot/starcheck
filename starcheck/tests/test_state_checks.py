from pathlib import Path

import chandra_maneuver
import numpy as np
import parse_cm.tests
import pytest
import Quaternion

from starcheck.state_checks import (
    get_obs_man_angle,
    make_man_table,
)


@pytest.mark.parametrize("angle", [0, 45, 90, 135, 180])
def test_make_man_table_durations(angle):
    """
    Test that the durations (and interpolated durations over them) in the maneuver angle duration
    table are reasonable using chandra_maneuver.duration directly as a reference.
    """

    man_table = make_man_table()

    # Check that the interpolated durations are reasonable
    dur_method = np.interp(angle, man_table["angle"], man_table["duration"])
    q0 = Quaternion.Quat(equatorial=(0, 0, 0))
    dur_direct = chandra_maneuver.duration(
        q0, Quaternion.Quat(equatorial=(angle, 0, 0))
    )
    assert np.isclose(dur_method, dur_direct, rtol=0, atol=10)


@pytest.mark.parametrize(
    "duration,expected_angle",
    [(240, 0), (1000, 27.7), (2000, 100.5), (3000, 175.5), (4000, 180)],
)
def test_make_man_table_angles(duration, expected_angle):
    """
    Test that the angles calculatd from interpolation into the maneuver angle duration table
    match reference values.
    """

    man_table = make_man_table()
    angle_calc = np.interp(duration, man_table["duration"], man_table["angle"])
    assert np.isclose(angle_calc, expected_angle, rtol=0, atol=0.1)


# These tstarts and expected angles are specific to the CR182_0803.backstop file
@pytest.mark.parametrize(
    "tstart,expected_angle",
    [(646940289.224, 142.6), (646947397.759, 0.0), (646843532.911, 91.8)],
)
def test_get_obs_man_angle(tstart, expected_angle):
    """
    Confirm that some of the angles calculated for a reference backstop file
    match reference values.
    """
    # Use a backstop file already in ska test data
    backstop_file = (
        Path(parse_cm.tests.__file__).parent / "data" / "CR182_0803.backstop"
    )
    man_angle_data = get_obs_man_angle(tstart, backstop_file)
    assert np.isclose(man_angle_data["angle"], expected_angle, rtol=0, atol=0.1)
