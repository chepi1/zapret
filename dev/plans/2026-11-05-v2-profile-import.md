# V2 fail-closed Flowseal importer

> Inline superpowers:executing-plans; autonomous user request. Code/data checks only; never execute upstream batch fixtures or replace live strategies.

**Goal:** refreshing strategies cannot silently lose unsupported conditions/actions or regress the already-fixed hostfakesplit altorder.

**Sources:** all22 original general*.bat from Flowseal/zapret-discord-youtube tag1.10.4 fetched through GitHub. Source Git blob SHA1 verified against raw bytes; dev/fixtures/flowseal-1.10.4/manifest.json records source path/blob and SHA256. Existing MIT/license notices retained; .bat.txt fixtures are data only and excluded from release ZIP.

**Architecture:** keep current section format/builder and all live strategy bytes. Tighten developer converter: exact option tokenization and supported profile selectors, explicit unknown-option/blob/mode/fooling errors with file/profile context, preserve altorder=1 using existing hostfakesplit_alt. Validate the full batch before output; --check covers22 profiles and exits nonzero on differences. Four known EXP differences remain explicit and require --allow-known-differences for conversion/check, with comments in generated output. Normal conversion still writes the18 converter-managed profiles, leaving the4 manually maintained profiles intact.

**Constraints:** no new runtime module, dependency, binary or strategy changes; Python standard library only. Our safety exclusions/list scoping remain intentional project differences, not claims of full upstream match equivalence. Strict unknown L3/L7/port selectors cannot silently broaden a match. Compatibility opt-in permits only the four identified EXP limitations, never unknown options/actions.

- [x] RED: initial8-test suite failed18 cases, plus focused selector/output/blob/match-condition REDs (dist/v2-converter-*-red.log).
- [x] GREEN: strict converter, batch prepare before writes, atomic per-file output, all22 action/hash checks and explicit EXP notes; existing live profiles unchanged. dist/v2-converter-final-target.log:8 tests, exit0.
- [x] Full final integration:54 offline groups exit0 dist/v2-final54-all.log, including profile/native drystrat and all15 converter tests after review fixes. One fresh read-only review; six Important fixed in one RED→GREEN pass, one harmless Minor deferred below. Local preview/legacy compatibility PASS; ready for local commit.

Review focus: unconsumed source tokens/quotes, overloaded --new scopes and duplicate section mapping, option values that are recognized by name but not representable, global wf arguments versus per-profile conditions, known differences opt-in not suppressing unknown errors.

Ruling: do not introduce a general recipe/model rewrite in this bounded repair. Pin current22 imports and fail on future unsupported semantics first; a canonical immutable snapshot/API remains a separate v2 milestone.

Ruling: full-corpus validation uncovered two additional pre-existing EXP match differences: fonts.googleapis.com exclusion and L7-only QUIC port scope. Add them to the explicit compatibility contract rather than silently whitelist them or change live strategy behavior. Current22 generated action sections now match all checked-in profiles exactly, including fixed hostfakesplit_alt. The section adapter is a closed source contract, not full source match equivalence.

Final review: six Important findings reproduced as24 failing assertions in dist/v2-converter-review-red.log. One fix pass adds protocol/action option-consumption checks, singleton uniqueness/TLS modifier grammar, both unique required wf masks, exact %BIN% blob paths, rejection of ambiguous fakedsplit positions, required voice L7/fake and game UDP any/cutoff/fake combinations. dist/v2-converter-review-final-target.log:15 tests pass, all22 pinned action outputs unchanged. Full53 before review passed dist/v2-converter-all.log; final54 after fixes passed dist/v2-final54-all.log. Existing administrator-only native Lua/store/timer branches remain skips.

Final: minor (deferred): identical repeated quic_ipset source profiles still coalesce idempotently. Different actions are rejected; current22 corpus contains no duplicate. Track source-kind duplicates when introducing a canonical recipe model; no current runtime behavior depends on this.

Ruling: retain explicit default tls_mod=none exactly as the existing ALT8 requires; an initial test normalization would have changed verified actions, so it was corrected before integration. Review's network efficacy/latency/full-policy equivalence exclusions remain outside this developer-tool repair.
