import os
import numpy as np
from astropy.table import Table
from Ska.Sun import position

TABLE = os.path.join(os.path.dirname(__file__), 'data', 'table_17.csv')
RESPONSIVITY = 0.0108 # (e-/sec/SI unit zodiacal flux)

def equat2eclip(ra, dec):
    """
    Convert from equatorial to ecliptic

    :param ra: Right Ascension (degrees)
    :param dec: Declination (degrees)
    :returns: ecliptic longitude, ecliptic latitude (degrees)
    """

    # Rough obliquity of ecliptic
    e = (23 + 26/60 + 21.406/3600) * np.pi/180
    alpha = np.radians(ra)
    delta = np.radians(dec)

    lamda = np.arctan2((np.sin(alpha) * np.cos(e) + np.tan(delta) * np.sin(e)), np.cos(alpha))
    sinb = np.sin(delta) * np.cos(e) - np.cos(delta) * np.sin(e) * np.sin(alpha)
    sinb = np.clip(sinb, a_min=-1, a_max=1)
    beta = np.arcsin(sinb)
    if beta < 0:
        beta += 2 * np.pi
    return np.degrees(lamda), np.degrees(beta)


def zoditable(table_file):
    table17 = Table.read(table_file, format='ascii')
    return np.array([i.as_void() for i in table17])


def zodi(ra, dec, time):
    """
    Return zodiacal brightness in e-/sec for attitude at time

    :param ra: Right Ascension (degrees)
    :param dec: Declination (degrees)
    :return: zodiacal brightness contribution to background in e-/sec
    """
    sun_ra, sun_dec = position(time)
    sun_el, sun_eb = equat2eclip(sun_ra, sun_dec)
    pos_el, pos_eb = equat2eclip(ra, dec)
    l_lsolar = np.abs(sun_el - pos_el)
    if l_lsolar > 180:
        l_lsolar = 360 - l_lsolar
    d_eb = np.abs(pos_eb)
    if d_eb > 180:
        d_eb = 360 - d_eb
    t17 = zoditable(TABLE)
    # The table has rows of delta longitude and cols of delta latitude
    # so this just reads a reasonable value from the table
    return t17[np.floor(l_lsolar)][np.floor(d_eb)] * RESPONSIVITY

