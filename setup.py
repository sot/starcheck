from distutils.core import setup
from starcheck.version import version
setup(name='starcheck',
      version=str(version),
      author='Jean Connelly',
      author_email='jconnelly@cfa.harvard.edu',
      packages=['starcheck'],
      )
