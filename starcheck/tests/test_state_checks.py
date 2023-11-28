import numpy as np
from pathlib import Path
import pytest

from astropy.table import Table
import chandra_maneuver
import parse_cm.tests
import Quaternion

from starcheck.state_checks import (
    make_man_table,
    get_obs_man_angle,
    calc_pcad_state_nman_sums,
)


@pytest.mark.parametrize("angle", [0, 45, 90, 135, 180])
def test_make_man_table_durations(angle):
    """
    Test that the calculated interpolated duractions in the maneuver angle duration
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
    [(646940289.224, 143.4), (646947397.759, 0.22), (646843532.911, 92.6)],
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
    angle = get_obs_man_angle(tstart, backstop_file)
    assert np.isclose(angle, expected_angle, rtol=0, atol=0.1)


def test_calc_pcad_state_nman_sums():
    # Make a synthetic table of pcad_mode states
    states = [
        {"tstart": 0, "tstop": 1000, "pcad_mode": "NPNT"},
        {"tstart": 1000, "tstop": 2000, "pcad_mode": "NMAN"},
        {"tstart": 2000, "tstop": 3000, "pcad_mode": "NMAN"},
        {"tstart": 3000, "tstop": 4000, "pcad_mode": "NPNT"},
        {"tstart": 4000, "tstop": 5000, "pcad_mode": "NMAN"},
        {"tstart": 5000, "tstop": 6000, "pcad_mode": "NPNT"},
    ]
    states = Table(states)
    nman_sums = calc_pcad_state_nman_sums(states)
    # Confirm that the first NPNT after an NMAN has the appropriate sum of NMAN times before it
    assert nman_sums[nman_sums["tstart"] == 3000]["nman_sum"][0] == 2000
    assert nman_sums[nman_sums["tstart"] == 5000]["nman_sum"][0] == 1000
