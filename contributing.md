# Contributing

Firstly, thank you for taking an interest in contributing! This is an
open-source project, and welcomes contributions in the form of feature code,
bug reports and fixes, tests, feature suggestions and anything else which may
help to make it better software.

This guide applies to every repository under
[github.com/propensive](https://github.com/propensive) which does not provide
its own.


## Before Starting

It&rsquo;s a good idea to [discuss](https://discord.gg/MBUrkTgMnA) potential
changes with one of the maintainers before starting work. Although efforts are
made to document future development work using the repository&rsquo;s issue
tracker, it will not always be up-to-date, and the maintainers may have useful
information to share on plans.

A bad scenario would be for a contributor to spend a lot of time producing a
pull request, only for it to be rejected by the maintainers for being
inconsistent with their plans. A quick conversation before starting work can
save a lot of time.

If a response is not forthcoming in the [Discord
chatroom](https://discord.gg/MBUrkTgMnA), open an issue in the repository or
contact the project maintainer directly _but publicly_. Please __do not__
contact the maintainer about technical issues privately, as it misses a good
opportunity to share knowledge with a wider audience, unless there is a good
reason to do so. Jon Pretty can usually be contacted [on
X](https://x.com/propensive).

All development work&mdash;whether bugfixing or implementing new
features&mdash;should have a corresponding issue before work starts. If you
have commit rights to the repository, push to a branch named after the issue
number, prefixed with `issue/`, for example, `issue/23`.


## Contribution standards

Pull requests should try to follow the coding style of existing code in the
repository. They are unlikely to be rejected on grounds of formatting, except
in extreme cases. These projects do not use automatic code-formatting because
it has proven to produce unreliable and unsatisfactory results (and
furthermore, hand-formatting is not particularly laborious).

Any code that is inconsistently formatted will be tidied up, if necessary, by
the project maintainers, though well-formatted code is appreciated.


## Pull requests and code reviews

Every change to `main` arrives through a pull request: direct pushes are
rejected. A pull request can be merged once its required status checks pass
and its branch is up-to-date with `main`, and it is merged by squashing, so its
title should read well as a single commit message. Commits must be signed.

Open a pull request when it is ready to merge, rather than as a draft, and
enable auto-merge if you have permission to, so that it merges as soon as its
checks pass. Its description should follow the template: a single summary
paragraph, then release notes addressed to users.

An approving review is not required, but maintainers may review any pull
request, and contributors are welcome to ask for a review or suggest a
reviewer. The preferred method of reviewing a pull request is to schedule a video call
with the reviewer and talk through it. It is much faster to share understanding
between the contributor and reviewer this way.

For code contributions, we prefer pull requests with corresponding tests, if
that's appropriate. Changes which break existing tests, however, are likely to
be rejected during review.


## Reporting issues

New issues are welcome, both as bug reports and feature suggestions. More
precision is preferable, and the clearest and most detailed reports will most
likely be addressed sooner, but a short report from a busy developer is still
preferred over a bug we never hear about. We will ask for more detail in triage
if it&rsquo;s needed.
