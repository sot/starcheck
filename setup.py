from setuptools import setup

from starcheck.version import version

setup(name='starcheck',
      version=version,
      author='Jean Connelly',
      author_email='jconnelly@cfa.harvard.edu',
      packages=['starcheck'],
      include_package_data=True,
      )
