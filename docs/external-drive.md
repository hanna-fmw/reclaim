# External drive — what goes on it, and how it is set up

Decided 2026-09-30, while freeing space before a recording. The internal drive is 228 GB
and regularly sits near full; the external is where the bulk goes.

## The drive

Seagate Game Drive for Xbox, 2 TB, USB 3. It is a **spinning disk, not an SSD**. That is
the fact everything below follows from: it is fast at reading and writing one big file in
a stream (~100 MB/s), and slow at lots of small scattered reads and writes.

## Format and partitions

Erase in Disk Utility, selecting the top-level drive entry (not the indented volume):

- Format: **APFS**
- Scheme: **GUID Partition Map**

Then **Partition into two**. Roughly 1.2 TB for Time Machine, 800 GB for storage.

Two partitions, not two APFS volumes in one container: volumes in a container share free
space, so Time Machine would grow until nothing was left for anything else.

## What goes on it

Storage partition — things that are large, cold, and already used:

- Raw meeting and screen recordings once they have been transcribed.
- Old project archives.
- Anything big that has not been opened in months.

**Recording directly to it is fine.** Screen capture writes ~20-40 MB/s in one stream,
well inside what the drive handles. Rough sizing: about 6 GB per 30 minutes.

## What does NOT go on it

- **Docker's disk image.** Docker Desktop can move it (Settings → Resources → Advanced →
  Disk image location), but a database does exactly the small scattered reads and writes a
  spinning disk is worst at, so local Supabase would crawl. It also makes Docker refuse to
  start whenever the drive is unplugged.
- **The only copy of anything.** Files moved here are no longer backed up by anything. Keep
  it to things that could be lost without real cost.

## The disk problem this was meant to solve

It mostly was not a storage problem. The internal drive filled because two local Supabase
stacks had been left running for days, holding ~12 GB of images that could not be pruned
while their containers were up. See `reclaim stacks`, which lists what is running and where
each project lives. The routine:

1. `supabase stop` in each project when finished (never `--no-backup`).
2. `docker image prune -a -f` when space is actually needed. Volumes are untouched, so
   local database data survives; the next `supabase start` re-downloads the images.
