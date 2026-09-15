# Day One import fixture

`day-one-official-shape.json` is a synthetic, sanitized fixture based on the structure of Day One’s [official 2023 sample](https://dayoneapp.com/wp-content/uploads/2023/02/2023-2-2-Journal.zip), linked by its [JSON guide](https://dayoneapp.com/blog/help_guides/importing-data-from-json-files/). Structure inspected on 2026-09-15.

It retains seven entries, twelve photo descriptors, Markdown image wrappers, identifier-to-md5 file lookup, richText JSON strings, heading/list/checkbox attributes and embedded photo groups. The official sample also has one photo reference without a matching photos-array descriptor; the fixture retains that defect as `fixture-unlisted-photo`, and tests require a recoverable-photo warning. Text, identities, dates and photo data are synthetic; tests generate JPEG files. This is reproducible format coverage, not certification of current exports from every platform or a real user's journal.
