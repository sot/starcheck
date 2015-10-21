import os
import numpy as np
import matplotlib.pyplot as plt

from astropy.table import Table, Column
import agasc
from Chandra.Time import DateTime
import Quaternion
from Ska.quatutil import radec2yagzag


# rc definitions
frontcolor = 'black'
backcolor = 'white'
plt.rcParams['lines.color'] = frontcolor
plt.rcParams['patch.edgecolor'] = frontcolor
plt.rcParams['text.color'] = frontcolor
plt.rcParams['axes.facecolor'] = backcolor
plt.rcParams['axes.edgecolor'] = frontcolor
plt.rcParams['axes.labelcolor'] = frontcolor
plt.rcParams['xtick.color'] = frontcolor
plt.rcParams['ytick.color'] = frontcolor
plt.rcParams['grid.color'] = frontcolor
plt.rcParams['figure.facecolor'] = backcolor
plt.rcParams['figure.edgecolor'] = backcolor
plt.rcParams['savefig.facecolor'] = backcolor
plt.rcParams['savefig.edgecolor'] = backcolor


def symsize(mag):
    # map mags to figsizes, defining
    # mag 6 as 20 and mag 11 as 1
    # interp should leave it at the bounding value outside
    # the range
    return np.interp(mag, [6.0, 11.0], [20.0, 1])


def plot_catalog_items(ax, catalog):
    cat = Table(catalog)
    face = backcolor
    gui = cat[cat['type'] == 'GUI']
    acq = cat[cat['type'] == 'ACQ']
    bot = cat[cat['type'] == 'BOT']
    fid = cat[cat['type'] == 'FID']
    mon = cat[cat['type'] == 'MON']
    for row in cat:
        ax.annotate("%s" % row['idx'],
                    xy=(row['yang'] - 120, row['zang'] + 60),
                    color='red',
                    fontsize=12)
    ax.scatter(gui['yang'], gui['zang'],
               facecolors=face,
               edgecolors='green',
               s=100)
    ax.scatter(bot['yang'], bot['zang'],
               facecolors=face,
               edgecolors='green',
               s=100)
    for acq_star in acq:
        acq_box = plt.Rectangle(
            (acq_star['yang'] - acq_star['halfw'],
             acq_star['zang'] - acq_star['halfw']),
            width=acq_star['halfw'] * 2,
            height=acq_star['halfw'] * 2,
            color='blue',
            fill=False)
        ax.add_patch(acq_box)
    for acq_star in bot:
        acq_box = plt.Rectangle(
            (acq_star['yang'] - acq_star['halfw'],
             acq_star['zang'] - acq_star['halfw']),
            width=acq_star['halfw'] * 2,
            height=acq_star['halfw'] * 2,
            color='blue',
            fill=False)
        ax.add_patch(acq_box)
    for mon_box in mon:
        # starcheck convention was to plot monitor boxes at 2X halfw
        box = plt.Rectangle(
            (mon_box['yang'] - (mon_box['halfw'] * 2),
             mon_box['zang'] - (mon_box['halfw'] * 2)),
             width=mon_box['halfw'] * 4,
             height=mon_box['halfw'] * 4,
             color='orange',
             fill=False)
        ax.add_patch(box)
    ax.scatter(fid['yang'], fid['zang'],
               facecolors=face,
               edgecolors='red',
               marker='o',
               s=175)
    ax.scatter(fid['yang'], fid['zang'],
               facecolors=face,
               edgecolors='red',
               marker='+',
               linewidth=1,
               s=175)


def plot_field_items(ax, field, quat, faint_plot_mag):
    field = Table(field)
    field = field[field['MAG_ACA'] < faint_plot_mag]
    yags = []
    zags = []
    for star in field:
        yag, zag = radec2yagzag(star['RA_PMCORR'],
                                star['DEC_PMCORR'],
                                quat)
        yag *= 3600
        zag *= 3600
        yags.append(yag)
        zags.append(zag)

    field.add_column(Column(name='yang', data=yags))
    field.add_column(Column(name='zang', data=zags))
    color = np.ones(len(field), dtype='|S10')
    color[:] = 'red'
    faint = ((field['CLASS'] == 0)
             & (field['MAG_ACA'] >= 10.7))
    color[faint] = 'orange'
    ok = ((field['CLASS'] == 0)
          & (field['MAG_ACA'] < 10.7))
    color[ok] = frontcolor
    size = symsize(field['MAG_ACA'])
    ax.scatter(field['yang'], field['zang'],
               c=color.tolist(), s=size, edgecolors=color.tolist())


def star_plot(catalog=None, quat=None, field=None, title=None, faint_plot_mag=10.7):
    fig = plt.figure(figsize=(5.2, 5.2))
    ax = fig.add_subplot(1, 1, 1)

    # plot the box and set the labels
    plt.xlim(2900, -2900)
    plt.ylim(-2900, 2900)
    b1hw = 2560
    box1 = plt.Rectangle((b1hw, -b1hw), -2 * b1hw, 2 * b1hw,
                         fill=False)
    ax.add_patch(box1)
    b2w = 2600
    box2 = plt.Rectangle((b2w, -b1hw), -2 * b2w, 2 * b1hw,
                         fill=False)
    ax.add_patch(box2)

    ax.scatter([-2700, -2700, -2700, -2700, -2700],
               [2400, 2100, 1800, 1500, 1200],
               c='orange', edgecolors='orange',
               s=symsize(np.array([10.0, 9.0, 8.0, 7.0, 6.0])))

    [l.set_rotation(90) for l in ax.get_yticklabels()]
    ax.grid()
    ax.set_ylabel("Zag (arcsec)")
    ax.set_xlabel("Yag (arcsec)")

    # plot starcheck catalog
    if catalog is not None:
        plot_catalog_items(ax, catalog)
    # plot field if present
    if field is not None:
        plot_field_items(ax, field, quat, faint_plot_mag)
    if title is not None:
        fig.suptitle(title)
    return fig


def plots_for_obsid(obsid, ra, dec, roll, starcat_time, catalog, outdir):
    ra = float(ra)
    dec = float(dec)
    roll = float(roll)
    field = agasc.get_agasc_cone(ra, dec,
                                 radius=1.5,
                                 date=DateTime(starcat_time).date)
    cat_plot = catalog_plot(ra, dec, roll, starcat_time, catalog, field=field,
                            title="RA %.2f Dec %.2f" % (ra, dec))
    cat_plot.savefig(os.path.join(outdir, 'stars_{}.png'.format(obsid)))
    plt.close(cat_plot)
    f_plot = field_plot(ra, dec, roll, starcat_time, field=field, title='field')
    f_plot.savefig(os.path.join(outdir, 'star_view_{}.png'.format(obsid)))
    plt.close(f_plot)


def catalog_plot(ra, dec, roll, starcat_time, catalog, field=None, title=None):
    quat = Quaternion.Quat([ra, dec, roll])
    if field is None:
        field = agasc.get_agasc_cone(ra, dec,
                                     radius=1.5,
                                     date=DateTime(starcat_time).date)
    fig = star_plot(catalog, quat, field, title=title)
    return fig


def field_plot(ra, dec, roll, starcat_time, field=None, title=None):
    quat = Quaternion.Quat([ra, dec, roll])
    if field is None:
        field = agasc.get_agasc_cone(ra, dec,
                                     radius=1.5,
                                     date=DateTime(starcat_time).date)
    fig = star_plot(catalog=None, quat=quat, field=field, title=title)
    return fig
