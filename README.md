UT Magic Redirect
=================

A UT redirect server which can serve files sourced from multiple remote
redirects.

It's a sort of proxying merging web-server.  You give it a list of redirect
URLs, and when a file is requested, it tries each redirect until it finds the
file.  Then it pipes it to any clients that are asking for it.

With `useDiskCache` disabled, the program uses no disk space, but obviously it
should be placed on a machine with fast network.  It does temporarily use
memory, as much as the size of the file(s) currently being streamed.


# Installation

To use this you need to install Node and put it on your PATH.  I do:

    % echo 'export PATH="$PATH:/opt/node/bin"' >> /home/redirect/.bashrc

for my user 'redirect'.

Then grab coffeescript:

    % npm install -g coffee-script

And you have all you need!  (You should have coffee on your PATH now too.)


# Configuration

Edit the `listenPort` and the list of redirects in `ut_magic_redirect.coffee`

If you enable `useDiskCache` then also set the `cacheDir`.

To disabling file caching from your own redirect (e.g. if it's running on
localhost), put that redirect URL in `doNotCacheFrom`.


# Running

You can run it by hand:

    % ./ut_magic_redirect.coffee

But if it works you probably want to use an init script so it starts up on
reboot.


# Init script

There is an init script included.  You will need to edit it to give it:

- the path to node
- the path to ut_magic_redirect.coffee
- the user you want to run as

Put the init script in /etc/init.d/.  I link it with:

    % ln -s <path>/init_script/ut_magic_redirect /etc/init.d/

Finally, Debian users can include it in the system statup with:

    % update-rc.d ut_magic_redirect defaults


