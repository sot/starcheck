# Licensed under a 3-clause BSD style license - see LICENSE.rst
from setuptools import setup


setup(name='starcheck',
      use_scm_version=True,
      setup_requires=['setuptools_scm', 'setuptools_scm_git_archive'],
      author='Jean Connelly',
      author_email='jconnelly@cfa.harvard.edu',
      packages=['starcheck'],
      include_package_data=True,
      scripts=['starcheck/src/starcheck'],
      )
