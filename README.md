# README #

Welcome to **Rockup**, the cloud-friendly incremental file backup system.

It is meant to be used in conjunction with on-line cloud storage.

### Rockup features ###

* Full and incremental backup modes
* Backup compression
* Backup encryption
* ... more

### Installation ###

**Rockup** is a 100% [Ruby](https://www.ruby-lang.org) application therefore it can run on any platform for which the Ruby runtime is available.

Therefore, in order to use **Rockup** it is necessary to install playform-specific Ruby runtime.

* Windows
> Refer to [RubyInstaller.org](https://rubyinstaller.org/) the all-in-one Ruby distribution.
* UNIX/Linux
> Refer to operation system -specific installation instructions.

Once the Ruby runtime is installed, it is time to install the **Rockup** itself. The latter is distribued in form of a [Gem](https://en.wikipedia.org/wiki/RubyGems) obtained from central repository [RubyGems.org](https://rubygems.org/).

Installing **Rockup** is a command line one-liner as follows:

`gem install rockup`

Once installed the **Rockup** can be invoked from command line with `rockup` command.

To see actual **Rockup** command line parameters run

`rockup -h`

### Authors & legal stuff ###

* **Rockup** is created by Oleg A. Khlybov <fougas@mail.ru>
* **Rockup** is a free software distributed under the terms of 3-clause BSD license.