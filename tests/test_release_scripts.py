"""Driving tests for WP #48 (epic #46 / #45): release-notes-from-main scripts.

Covers the three requirements the plan classifies as `driving-test`:

  R1 - .github/scripts/prev-release-tag.sh   (previous-release resolution)
  R2 - .github/scripts/marketplace-payload.sh (dispatch JSON with changelog)
  R3 - .github/scripts/preflight-check.sh     (src/<TAG> marker pre-flight)

None of the three scripts exist yet at phase=tests time (this is the
intended RED state: `.github/scripts/` is not created in this phase). Every
test here is expected to fail because bash cannot find the script file,
not because of an assertion mismatch against a real implementation.

All three scripts are invoked as `bash <repo-root-relative POSIX path>
<args...>` with the tag list piped in on stdin, per the plan's constraint
that they must be driveable without a real git repository. On Windows the
shell is resolved to the absolute Git-for-Windows bash, never a bare
`bash` off PATH (a `bash` alias/shim on PATH is not guaranteed to be the
same interpreter the CI runner uses).
"""

import json
import os
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent

PREV_RELEASE_TAG_SCRIPT = ".github/scripts/prev-release-tag.sh"
PREFLIGHT_CHECK_SCRIPT = ".github/scripts/preflight-check.sh"
MARKETPLACE_PAYLOAD_SCRIPT = ".github/scripts/marketplace-payload.sh"


def _resolve_bash() -> str:
    if os.name == "nt":
        # Never a bare "bash" from PATH - pin the actual Git-for-Windows
        # interpreter so the test harness matches what CI uses.
        return r"C:\Program Files\Git\bin\bash.exe"
    return "bash"


BASH_PATH = _resolve_bash()


def run_script(script_relpath, args=None, stdin_text="", env=None):
    """Run a repo-root-relative script under bash, feeding it stdin_text."""
    cmd = [BASH_PATH, script_relpath, *(args or [])]
    return subprocess.run(
        cmd,
        input=stdin_text,
        capture_output=True,
        text=True,
        cwd=str(REPO_ROOT),
        env=env,
    )


# ---------------------------------------------------------------------------
# R1 - prev-release-tag.sh
# ---------------------------------------------------------------------------

# (case_id, tags_on_stdin, plugin_name, version_being_created, expected_stdout)
PREV_RELEASE_TAG_CASES = [
    (
        "basic_ordering",
        ["myplugin--v0.9.0", "myplugin--v0.10.0"],
        "myplugin",
        "1.0.0",
        "myplugin--v0.10.0",
    ),
    (
        "prerelease_rc_ordering_rc10_above_rc2",
        ["myplugin--v1.0.0-rc.2", "myplugin--v1.0.0-rc.10"],
        "myplugin",
        "1.0.0",
        "myplugin--v1.0.0-rc.10",
    ),
    (
        "prerelease_sorts_below_its_release",
        ["myplugin--v1.0.0-rc.1", "myplugin--v1.0.0"],
        "myplugin",
        "1.0.1",
        "myplugin--v1.0.0",
    ),
    (
        "excludes_tag_being_created",
        ["myplugin--v1.0.0", "myplugin--v0.9.0"],
        "myplugin",
        "1.0.0",
        "myplugin--v0.9.0",
    ),
    (
        "excludes_foreign_and_bare_tags",
        ["other-plugin--v1.0.0", "v1.0.0", "myplugin--v0.5.0"],
        "myplugin",
        "1.0.0",
        "myplugin--v0.5.0",
    ),
    (
        "excludes_src_marker_tags",
        ["src/myplugin--v0.9.0", "myplugin--v0.8.0"],
        "myplugin",
        "1.0.0",
        "myplugin--v0.8.0",
    ),
    (
        "empty_tag_list",
        [],
        "myplugin",
        "1.0.0",
        "",
    ),
    (
        "no_lower_tag_exists",
        ["myplugin--v2.0.0"],
        "myplugin",
        "1.0.0",
        "",
    ),
    (
        "rejects_leading_zero_version_as_non_semver",
        ["myplugin--v1.02.0", "myplugin--v1.1.0"],
        "myplugin",
        "2.0.0",
        "myplugin--v1.1.0",
    ),
    (
        "rejects_build_metadata_tag",
        ["myplugin--v1.0.0+build5", "myplugin--v0.9.0"],
        "myplugin",
        "1.0.0",
        "myplugin--v0.9.0",
    ),
    (
        # R4 (review round 1): a foreign-plugin tag with a higher version
        # than the one being created must never leak into the answer just
        # because it numerically outranks everything else on the list -
        # plugin-name prefix filtering must be applied as an independent
        # condition, not as a side effect of the version-ordering check.
        "foreign_plugin_higher_version_never_leaks",
        ["other-plugin--v9.9.9", "agent-unity-wrapper--v0.5.0"],
        "agent-unity-wrapper",
        "1.0.0",
        "agent-unity-wrapper--v0.5.0",
    ),
    (
        # F1 (review round 2): the case above doesn't actually exercise the
        # prefix filter as the load-bearing reason for exclusion - its
        # foreign tag (v9.9.9) is already excluded by the unrelated
        # version-ordering check (9.9.9 > 1.0.0), regardless of whether
        # prefix filtering exists at all.
        #
        # A *named*-foreign-plugin fixture (e.g. "other-plugin--v0.1.0")
        # turns out not to be load-bearing either, verified by mutation
        # testing: with the prefix-filter `case` block removed,
        # `${tag#"$PREFIX"}` leaves a non-matching tag's string untouched,
        # and "other-plugin--v0.1.0" still fails parse_semver on its own
        # (it starts with letters, not a digit) - so it is excluded by the
        # semver-parse check regardless of the prefix filter's presence.
        #
        # The genuinely load-bearing case is a *bare* numeric tag with no
        # plugin-name segment at all - it parses as valid, lower-than-target
        # semver all by itself, so only the prefix filter (not version
        # ordering, not the semver-parse check) stands between it and being
        # incorrectly selected. Confirmed by mutation testing: this case
        # FAILS (selects "0.6.0" instead of "agent-unity-wrapper--v0.5.0")
        # when the prefix-filter block is removed, and PASSES once it is
        # restored.
        "bare_tag_with_no_plugin_prefix_never_leaks",
        ["0.6.0", "agent-unity-wrapper--v0.5.0"],
        "agent-unity-wrapper",
        "1.0.0",
        "agent-unity-wrapper--v0.5.0",
    ),
]


@pytest.mark.parametrize(
    "case_id,tags,plugin,version,expected",
    PREV_RELEASE_TAG_CASES,
    ids=[c[0] for c in PREV_RELEASE_TAG_CASES],
)
def test_prev_release_tag(case_id, tags, plugin, version, expected):
    stdin_text = "\n".join(tags)
    result = run_script(PREV_RELEASE_TAG_SCRIPT, [plugin, version], stdin_text=stdin_text)
    assert result.returncode == 0, f"[{case_id}] stderr: {result.stderr!r}"
    assert result.stdout.strip() == expected, (
        f"[{case_id}] stdout: {result.stdout!r} stderr: {result.stderr!r}"
    )


# ---------------------------------------------------------------------------
# R2 - marketplace-payload.sh
# ---------------------------------------------------------------------------


def base_env(**overrides):
    env = os.environ.copy()
    defaults = {
        "NAME": "agent-unity-wrapper",
        "DESC": "A pure skill plugin for Unity.",
        "REPO": "seretos-agents/agent-unity-wrapper",
        "CATEGORY": "skill",
        "VERSION": "1.0.0",
        "TAG": "agent-unity-wrapper--v1.0.0",
        "CHANGELOG": "",
    }
    defaults.update(overrides)
    env.update(defaults)
    return env


def test_marketplace_payload_changelog_roundtrips_hostile_string_exactly():
    hostile = (
        "#123 Fixed `code` and \"quotes\" and \\ backslash\n"
        "and $VAR and $(id) and ${VAR}\n"
        "trailing newline follows\n"
    )
    env = base_env(CHANGELOG=hostile)
    result = run_script(MARKETPLACE_PAYLOAD_SCRIPT, env=env)
    assert result.returncode == 0, f"stderr: {result.stderr!r}"
    payload = json.loads(result.stdout)
    assert payload["client_payload"]["changelog"] == hostile


def test_marketplace_payload_omits_changelog_key_when_empty():
    env = base_env(CHANGELOG="")
    result = run_script(MARKETPLACE_PAYLOAD_SCRIPT, env=env)
    assert result.returncode == 0, f"stderr: {result.stderr!r}"
    payload = json.loads(result.stdout)
    expected_keys = sorted(
        ["category", "description", "description_url", "icon", "name", "ref", "repo", "version"]
    )
    assert sorted(payload["client_payload"].keys()) == expected_keys


def test_marketplace_payload_includes_changelog_key_and_full_keyset_when_set():
    env = base_env(CHANGELOG="some release notes")
    result = run_script(MARKETPLACE_PAYLOAD_SCRIPT, env=env)
    assert result.returncode == 0, f"stderr: {result.stderr!r}"
    payload = json.loads(result.stdout)
    expected_keys = sorted(
        [
            "category",
            "changelog",
            "description",
            "description_url",
            "icon",
            "name",
            "ref",
            "repo",
            "version",
        ]
    )
    assert sorted(payload["client_payload"].keys()) == expected_keys


def test_marketplace_payload_static_fields_and_derived_urls():
    env = base_env(
        REPO="seretos-agents/agent-unity-wrapper",
        TAG="agent-unity-wrapper--v1.0.0",
        CHANGELOG="notes",
    )
    result = run_script(MARKETPLACE_PAYLOAD_SCRIPT, env=env)
    assert result.returncode == 0, f"stderr: {result.stderr!r}"
    payload = json.loads(result.stdout)
    assert payload["event_type"] == "plugin-release"
    cp = payload["client_payload"]
    assert cp["ref"] == "agent-unity-wrapper--v1.0.0"
    assert (
        cp["icon"]
        == "https://raw.githubusercontent.com/seretos-agents/agent-unity-wrapper/agent-unity-wrapper--v1.0.0/assets/icon.png"
    )
    assert (
        cp["description_url"]
        == "https://raw.githubusercontent.com/seretos-agents/agent-unity-wrapper/agent-unity-wrapper--v1.0.0/description.md"
    )


def test_marketplace_payload_maps_each_field_individually():
    # R5 (review round 1): assert NAME/REPO/CATEGORY/VERSION are each mapped
    # to their own client_payload key, with distinct, non-overlapping fixture
    # values so a cross-mapping bug (e.g. category hardcoded to "skill", or
    # name reading $VERSION by mistake) can't hide behind coincidentally
    # equal strings the way key-set-only assertions would let it.
    env = base_env(
        NAME="agent-unity-wrapper",
        VERSION="1.2.3",
        CATEGORY="skill",
        REPO="seretos-agents/agent-unity-wrapper",
    )
    result = run_script(MARKETPLACE_PAYLOAD_SCRIPT, env=env)
    assert result.returncode == 0, f"stderr: {result.stderr!r}"
    cp = json.loads(result.stdout)["client_payload"]
    assert cp["name"] == "agent-unity-wrapper"
    assert cp["repo"] == "seretos-agents/agent-unity-wrapper"
    assert cp["category"] == "skill"
    assert cp["version"] == "1.2.3"


def test_marketplace_payload_derived_urls_change_with_repo_and_tag():
    # R6 (review round 1, nit): exercise a second REPO/TAG pair distinct from
    # the one used elsewhere in this file, so the suite can distinguish real
    # jq interpolation of $REPO/$TAG from a hardcoded URL literal that would
    # keep passing the single-fixture assertion above.
    env = base_env(
        REPO="someone-else/other-repo",
        TAG="other-repo--v2.5.0",
        CHANGELOG="notes",
    )
    result = run_script(MARKETPLACE_PAYLOAD_SCRIPT, env=env)
    assert result.returncode == 0, f"stderr: {result.stderr!r}"
    cp = json.loads(result.stdout)["client_payload"]
    assert cp["ref"] == "other-repo--v2.5.0"
    assert (
        cp["icon"]
        == "https://raw.githubusercontent.com/someone-else/other-repo/other-repo--v2.5.0/assets/icon.png"
    )
    assert (
        cp["description_url"]
        == "https://raw.githubusercontent.com/someone-else/other-repo/other-repo--v2.5.0/description.md"
    )


def test_marketplace_payload_desc_with_double_quote_stays_intact():
    desc = 'He said "hi" to everyone.'
    env = base_env(DESC=desc)
    result = run_script(MARKETPLACE_PAYLOAD_SCRIPT, env=env)
    assert result.returncode == 0, f"stderr: {result.stderr!r}"
    payload = json.loads(result.stdout)
    assert payload["client_payload"]["description"] == desc


# ---------------------------------------------------------------------------
# R3 - preflight-check.sh
# ---------------------------------------------------------------------------


def run_preflight(tag, prev_tag=None, tags=None):
    args = [tag] if prev_tag is None else [tag, prev_tag]
    stdin_text = "\n".join(tags or [])
    return run_script(PREFLIGHT_CHECK_SCRIPT, args, stdin_text=stdin_text)


def test_preflight_fails_when_tag_marker_already_exists():
    result = run_preflight("myplugin--v1.0.0", tags=["src/myplugin--v1.0.0", "myplugin--v0.9.0"])
    assert result.returncode == 1
    assert "::error::" in result.stderr
    assert "src/myplugin--v1.0.0" in result.stderr


def test_preflight_fails_when_prev_marker_missing():
    result = run_preflight(
        "myplugin--v1.0.0", prev_tag="myplugin--v0.9.0", tags=["myplugin--v0.9.0"]
    )
    assert result.returncode == 1
    assert "::error::" in result.stderr
    assert "git tag src/myplugin--v0.9.0 <head_sha>" in result.stderr
    assert "git push origin src/myplugin--v0.9.0" in result.stderr


def test_preflight_tag_marker_exists_wins_over_prev_marker_missing():
    result = run_preflight(
        "myplugin--v1.0.0", prev_tag="myplugin--v0.9.0", tags=["src/myplugin--v1.0.0"]
    )
    assert result.returncode == 1
    assert "src/myplugin--v1.0.0" in result.stderr
    assert "git tag src/myplugin--v0.9.0" not in result.stderr


def test_preflight_first_release_with_no_prev_tag_succeeds_silently():
    result = run_preflight("myplugin--v1.0.0", prev_tag=None, tags=["myplugin--v0.5.0"])
    assert result.returncode == 0
    assert result.stdout == ""
    assert result.stderr == ""


def test_preflight_unrelated_foreign_tags_trigger_nothing():
    result = run_preflight(
        "myplugin--v1.0.0",
        prev_tag="myplugin--v0.9.0",
        tags=["src/other-plugin--v1.0.0", "other-plugin--v2.0.0", "src/myplugin--v0.9.0"],
    )
    assert result.returncode == 0
    assert result.stdout == ""
    assert result.stderr == ""
