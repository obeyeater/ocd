# Optimally Configured Dotfiles

Do you have dotfiles skewed across lots of different machines?

This script allows you to easily track and synchronize them using Git as a backend. It makes
setting up a new system very fast and simple, and minimizes "config drift", i.e. slightly
different versions of your configs scattered across the various machines you use.

OCD works by configuring symlinks for all your dotfiles pointing at the Git-tracked versions in `~/.ocd`, like so:
```
$ ls -l ~/.bashrc
lrwxrwxrwx 1 luser luser 12 Aug 25 02:25 /home/luser/.bashrc -> .ocd/.bashrc
```

OCD functions are wrappers for moving files in and out of "tracked" status,
restoring files, backup changes to the upstream Git repository, and so forth.

To use this, you just need a centrally accessible Git repo (e.g. a repo called "`dotfiles`"
on Github) and this one shellscript.

## Download the OCD script
Replace `~/bin` with wherever you like to keep your tools. Make sure it's in your `PATH`.
```
curl https://raw.githubusercontent.com/nycksw/ocd/master/ocd.sh -o ~/bin/ocd
chmod +x ~/bin/ocd
```
## Set the repository
You'll need a Git repository for storing your dotfiles. Put its URL in your OCD config:
```
echo 'OCD_REPO=git@github.com:luser/my-dotfiles.git' >> ~/.ocd.conf
```
## Install an SSH key for the repository
Below shows how to create a new SSH keypair for the host. 
```
ssh-keygen -t ed25519 -f ~/.ssh/your_deploy_key
```

Add your new public key to your origin repository. Here are the
[GitHub instructions for managing deploy keys](https://docs.github.com/en/authentication/connecting-to-github-with-ssh/managing-deploy-keys).

OCD will work if you have an `ssh-agent` running with the appropriate key/config.
To use a specific SSH deploy key for all the Git commands, set `OCD_IDENT`:
```
echo 'OCD_IDENT=~/.ssh/your_deploy_key' >> ~/.ocd.conf
```

## Install your dotfiles via OCD
OCD will overwrite your local files with whatever is in the repository, so make sure the Git repo
has the most recent versions.

To install your dotfiles into your home directory:
```
ocd install
```
When you run `ocd install` it does the following:

  * checks if an SSH identity is available
  * runs `git clone`, syncing your central dotfile repository into your OCD directory; the default destination is `~/.ocd`.
  * creates symlinks in your home directory pointing at versions in `~/.ocd` (the local Git repo).
  * (Debian-only) reports which of your favorite packages are missing from the system;
    * this requires keeping a list of your favorite packages in a file called `~/.favpkgs`.
  * offers to install `bash` completion for itself; this is optional and requires `sudo`.

# Usage
```
ocd install:        install files from <OCD_REPO>
ocd add FILE:       track a new file in the repository
ocd rm FILE:        stop tracking a file in the repository
ocd restore:        pull from git master and copy files to homedir
ocd backup:         push all local changes upstream
ocd status [FILE]:  check if a file is tracked, or if there are uncommited changes
ocd export FILE:    create a tar.gz archive with everything in ~/.ocd
ocd missing-pkgs:   compare system against ~/.favpkgs and report missing
```

# Writing portable config files

This process may require you think a little differently about your dotfiles to
make sure they're portable across all the systems you use. For example, my
`.bashrc` is suitable for *every* system I use, and I put domain-centric or
host-centric customizations (for example, hosts I use at work) in a separate file.

Consider these lines, which I include at the end of my `.bashrc`:

```
source $HOME/.bashrc_$(hostname -f)
source $HOME/.bashrc_$(dnsdomainname)
```

This way, settings are only applied in the appropriate context.

# Managing changes to tracked files

When I log in to a system that I haven't worked on in a while, the first thing
I do is run `ocd restore`. Any time I make a config change, I run `ocd backup`.

*Note*: the actual dotfiles are linked to their counterparts in the
local `~/.ocd` git branch, so there's no need to copy changes anywhere before
committing. Just edit in place and run `ocd backup`.

There are also helper functions: `ocd status` tells me if I'm behind the
master, and `ocd missing-pkgs` tells me if my installed
packages differ from my basic preferences recorded in `~/.favpkgs`; for
example, your `openbox` autostart may call programs that are not installed
by default on a new system, and so `ocd missing-pkgs` is just a very simple way
to record these dependencies and make it easy to install them, e.g.: `sudo
apt-get install $(ocd missing-pkgs)`

Adding new files is just:
  * `ocd add <filename>`
  * `ocd backup`

Finally, you may also use `ocd export filename.tar.gz` to create an archive
with all your files. This is useful if you'd like to copy your files to
another host where you don't want to use OCD.

### Example output

If I change something on any of my systems, I can easily push the change
back to my Git repository. For example:

```
$ ocd backup
✓ git status in /home/e/.ocd:

On branch master
Your branch is up to date with 'origin/master'.

Changes not staged for commit:
  (use "git add <file>..." to update what will be committed)
  (use "git restore <file>..." to discard changes in working directory)
        modified:   .bashrc
[...]
Commit everything and push to 'git@github.com:nycksw/dotfiles.git'? [NO/yes]: yes
[master 5ac968a] Remove bash builder line.
 1 file changed, 1 deletion(-)
[...]
To github.com:nycksw/dotfiles.git
   684882f..5ac968a  master -> master
```

# Caveats

## Merges
Occasionally I'll change something on more than one system without
running `ocd backup`, and git will complain that it can't run `git pull` without
first committing local changes. This is easy to fix by changing into the `~/.ocd` 
directory and doing a typical merge, a simple `git push`, `git checkout -f $filename`
to overwrite changes, or some other resolution.

# Portability of this script

I've run OCD on several different distributions, but it might not work on
yours. Fork this repo and go nuts. `ocd.sh` is relatively simple.

I'd love to receive pull requests that make this script more portable, just so long as
the changes don't result in a script that's too long or complicated to maintain.

## Alternatives

There are other dotfile managers! You should almost certainly use one of them instead of
this mine. Here's a list:

* [dotbot](https://github.com/anishathalye/dotbot)
* [chezmoi](https://www.chezmoi.io/why-use-chezmoi/)
* [yadm](https://yadm.io/)
* [GNU Stow](https://www.gnu.org/software/stow/)

 I wrote OCD before any of these existed, and I've never tried them because they seem too
 heavyweight for my taste, but I'm sure they offer advantages over this little pet script
 of mine.
