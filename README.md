# voxhora-mac

This repository exists for one reason: to keep the Sparkle update feed at its
original URL alive.

Voxhora-Mac builds up to and including 0.2.86 have this URL compiled into them:

    https://raw.githubusercontent.com/SanPatriciodeCuernavaca/voxhora-mac/main/appcast.xml

That URL cannot be changed on an installed copy — it is baked into the binary,
and Sparkle reports a failed update check to nobody. If this repository were
deleted or made private, every one of those installs would stop receiving
updates permanently, without any visible error.

So `appcast.xml` stays here, and its enclosure points at voxhora.app. Older
installs keep updating and migrate to the voxhora.app feed the next time their
owner opens the app.

**Do not delete this repository. Do not make it private.**

The application source lives elsewhere and is private.
