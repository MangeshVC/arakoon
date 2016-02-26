%global __os_install_post %{nil}

Summary: Arakoon
Name: arakoon
Version: 1.9.2
Release: 3%{?dist}
License: Apache 2.0
Requires: libev >= 4
Source: https://github.com/Incubaid/arakoon
URL: http://www.arakoon.org
ExclusiveArch: x86_64

%description
Arakoon, a key-value store

%prep
cd ../SOURCES/arakoon
make clean

%build
cd ../SOURCES/arakoon
make

%install
cd ../SOURCES/arakoon
mkdir -p %{buildroot}%{_bindir}
cp LICENSE %{_builddir}
cp README.md %{_builddir}/README
cp arakoon.native %{buildroot}%{_bindir}/arakoon

%files
%doc README LICENSE
%{_bindir}/arakoon

%changelog
* Fri Feb 26 2016 Romain Slootmaekers <romain.slootmaekers@openvstorage.com> - 1.9.2
- Create arakoon 1.9.2 RPM package
* Fri Feb 19 2016 Romain Slootmaekers <romain.slootmaekers@openvstorage.com> - 1.9.1
- Create arakoon 1.9.1 RPM package
* Fri Feb 12 2016 Romain Slootmaekers <romain.slootmaekers@openvstorage.com> - 1.9.0
- Create arakoon 1.9.0 RPM package
* Mon Jan 25 2016 Romain Slootmaekers <romain.slootmaekers@openvstorage.com> - 1.8.13
- Create arakoon 1.8.13 RPM package
* Wed Dec 23 2015 Jan Doms <jan.doms@gmail.com> - 1.8.12
- Create arakoon 1.8.12 RPM package
* Fri Dec 11 2015 Romain Slootmaekers <romain.slootmaekers@openvstorage.com> - 1.8.11
- Create arakoon 1.8.11 RPM package
* Mon Nov 02 2015 Romain Slootmaekers <romain.slootmaekers@openvstorage.com> - 1.8.10
- Create arakoon 1.8.10 RPM package
* Tue Aug 25 2015 Jan Doms <jan.doms@gmail.com> - 1.8.9
- Create arakoon 1.8.9 RPM package
* Wed Aug 05 2015 Jan Doms <jan.doms@gmail.com> - 1.8.8
- Create arakoon 1.8.8 RPM package
* Mon Aug 03 2015 Jan Doms <jan.doms@gmail.com> - 1.8.7
- Create arakoon 1.8.7 RPM package
* Fri Jun 26 2015 Jan Doms <jan.doms@gmail.com> - 1.8.6
- Create arakoon 1.8.6 RPM package
* Fri Jun 12 2015 Jan Doms <jan.doms@gmail.com> - 1.8.5
- Create arakoon 1.8.5 RPM package
* Tue Jun 09 2015 Jan Doms <jan.doms@gmail.com> - 1.8.4
- Create arakoon 1.8.4 RPM package
* Fri May 22 2015 Romain Slootmaekers <romain.slootmaekers@cloudfounders.com> - 1.8.3
- Create arakoon 1.8.3 RPM package
* Mon May 04 2015 Jan Doms <jan.doms@gmail.com> - 1.8.2
- Create arakoon 1.8.2 RPM package
* Fri Apr 03 2015 Jan Doms <jan.doms@gmail.com> - 1.8.1
- Create arakoon 1.8.1 RPM package
* Tue Jan 20 2015 Jan Doms <jan.doms@gmail.com> - 1.8.0
- Create arakoon 1.8.0 RPM package
* Thu Oct 02 2014 Kenneth Henderick <kenneth.henderick@cloudfounders.com> - 1.7.4-3
- Create RPM packages containing more information