"""
Checkout spaces and get the
"""

checkout.add_repo(
    rule = {"name": "spaces"},
    repo = {
        "url": "https://github.com/work-spaces/spaces",
        "rev": "main",
        "checkout": "Revision",
        "clone": "Default",
    },
)
