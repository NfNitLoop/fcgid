fcgid
=====

FcgiD is a pure D implementation of the [FastCGI] protocol. This library aims to provide a simple interface for writing an FCGI application. 

[FastCGI]: http://www.fastcgi.com/drupal/node/6?q=node/22

Getting Started
---------------

Take a look at the [sample] application for setting up a quick web application.

In the sample/ subdir, run `vagrant up` to boot up a [Vagrant] instance and see the sample app running.

Read the paltry [api docs].

[sample]: ./sample/src/app.d
[Vagrant]: https://www.vagrantup.com/
[api docs]: ./docs/api/


Using
-----

I haven't registered this project in dub yet, so for now, `git clone` it, then use `dub add-path` to make your dub aware of it.
Then you should be able to depend on `fcgid:lib` and import `nfnitloop.fcgid.application` to get started!


Current Status
--------------

Features currently completed: 

 * Multiple simultaneous connections from the web server. 
 * FCGI and HTTP (GET) parameters. 
 * Writing stdout/stderr responses. 
 
... but FcgiD is not quite complete yet.  Things that I'll be working on next: 

 * handle stdin. (HTTP POST!)
 * Handle the rest of the RecordTypes. 
 * better (read: some) error handling
 * Code cleanup. It feels really messy to me at the moment.  Sorry about that.

Things that might come later: 

 * Full single-connection Request multiplexing. (Right now, there's only one thread per connection from the server.) Not holding my breath on this one, though, as mod_fastcgi doesn't even support this.
 * Suppport for the Authorizer role. 
 * Support for the Filter role.
 * Autodetect when run from outside a web server and simulate HTTP requests for CLI testing? 



