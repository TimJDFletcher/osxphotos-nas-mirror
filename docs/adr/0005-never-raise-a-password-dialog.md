# Never raise a password dialog

Runs are unattended under launchd, and a dialog nobody answers would hang the run. Before mounting, the tool checks the login keychain for an SMB password for the user at the NAS. If there is none, the run ends with the outcome `no-credentials`.

The password is saved the Finder way: Go > Connect to Server, then tick "Remember this password in my keychain".
