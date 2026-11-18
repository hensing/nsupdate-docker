"""Make nsupdate's social-login buttons start the login with a POST.

social-auth-app-django >= 6.0 only accepts POST (with a CSRF token) on
`social:begin`; a GET answers 405. nsupdate's templates (release and master)
still start the flow with a GET: a plain link on the login page and a
`method="get"` form on the account settings page. This rewrites both into
CSRF-protected POST forms.

Each rewrite must match exactly once, otherwise the build fails -- an upstream
template change has to be looked at, not silently skipped. Once upstream ships
POST forms itself, the script fails on the first run and can be removed.

Usage: python social_begin_post.py   (run with the image's venv python)
"""

import importlib.util
import pathlib
import re
import sys

# Locate the installed package without importing it (no Django settings needed).
spec = importlib.util.find_spec("nsupdate")
if spec is None or not spec.submodule_search_locations:
    sys.exit("social_begin_post: nsupdate package not found")
pkg = pathlib.Path(next(iter(spec.submodule_search_locations)))

REWRITES = [
    (
        # Login page: <a class="btn ..." role="button" href="{% url 'social:begin' backend %}"> icon {{ backend }} </a>
        "login/templates/login.html",
        re.compile(
            r"""<a class="(?P<cls>btn [\w-]+)" role="button" href="\{% url 'social:begin' backend %\}">"""
            r"""(?P<body>\s*<i class="[^"]*"></i> \{\{ backend \}\}\s*)</a>"""
        ),
        r"""<form method="post" action="{% url 'social:begin' backend %}" style="display: inline-block;">"""
        r"""{% csrf_token %}<button type="submit" class="\g<cls>">\g<body></button></form>""",
    ),
    (
        # Account settings: "Associate with remote Account" buttons.
        "accounts/templates/accounts/user_settings_account.html",
        re.compile(
            r"""<form method="get" action="\{% url 'social:begin' backend %\}"(?P<attrs>[^>]*)>"""
        ),
        r"""<form method="post" action="{% url 'social:begin' backend %}"\g<attrs>>{% csrf_token %}""",
    ),
]

for rel, pattern, repl in REWRITES:
    path = pkg / rel
    text = path.read_text(encoding="utf-8")
    new, count = pattern.subn(repl, text)
    if count != 1:
        sys.exit(f"social_begin_post: expected 1 match in {path}, found {count}")
    path.write_text(new, encoding="utf-8")
    print(f"social_begin_post: patched {path}")
