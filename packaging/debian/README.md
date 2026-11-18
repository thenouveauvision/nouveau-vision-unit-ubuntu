# Debian Packaging

The qualified public package is:

`nvu 1.0.0-2 amd64`

The recommended binary distribution channel is the signed APT repository:

https://apt.nvu.us/

The Debian package installs the NVU distribution tooling under:

- `/usr/bin/nvu`
- `/usr/lib/nvu-installer`

Package installation does not deploy the NVU runtime.

Deployment is an explicit administrator action:

`sudo nvu install --fqdn node.example.com`

Qualification is performed with:

`sudo nvu qualify --fqdn node.example.com`
