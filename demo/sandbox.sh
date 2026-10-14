#!/usr/bin/env bash
# Create the made-up project the demo media is recorded in: a tiny shop
# backend, committed to its own git repository so the agents view has status
# letters to show. Wipes and recreates it on every run.
#
# Usage: sandbox.sh <project-dir>

set -euo pipefail

dir="${1:?usage: sandbox.sh <project-dir>}"
rm -rf "$dir"
mkdir -p "$dir/shop" "$dir/tests"
cd "$dir"

cat >README.md <<'EOF'
# acme-shop

A tiny shop backend: a cart, prices and stock.
EOF

# The recorded CLI has no Bash (a command waiting for approval would stall a
# recording), yet the model reaches for it to check its edits, and the refusal
# is drawn as an error. Asked here not to, it does not.
cat >CLAUDE.md <<'EOF'
Make only the change you are asked for, then stop. Do not run commands, tests
or type checkers, and do not mention this note in your replies.
EOF

cat >shop/__init__.py <<'EOF'
EOF

cat >shop/cart.py <<'EOF'
from shop.pricing import line_total


class Cart:
    def __init__(self):
        self.items = {}

    def add_item(self, sku, price, quantity=1):
        entry = self.items.setdefault(sku, {"price": price, "quantity": 0})
        entry["quantity"] += quantity

    def total(self):
        return sum(line_total(e["price"], e["quantity"]) for e in self.items.values())

    def is_empty(self):
        return not self.items
EOF

cat >shop/pricing.py <<'EOF'
TAX_RATE = 0.2


def line_total(price, quantity):
    return price * quantity


def with_tax(amount):
    return round(amount * (1 + TAX_RATE), 2)
EOF

cat >shop/inventory.py <<'EOF'
class Inventory:
    def __init__(self, stock=None):
        self.stock = dict(stock or {})

    def available(self, sku):
        return self.stock.get(sku, 0)

    def reserve(self, sku, quantity):
        if self.available(sku) < quantity:
            raise ValueError(f"not enough {sku} in stock")
        self.stock[sku] -= quantity
EOF

cat >tests/test_cart.py <<'EOF'
from shop.cart import Cart


def test_total_sums_lines():
    cart = Cart()
    cart.add_item("apple", 0.5, 4)
    cart.add_item("pear", 0.75)
    assert cart.total() == 2.75
EOF

git init -q
git -c user.name=demo -c user.email=demo@example.com add .
git -c user.name=demo -c user.email=demo@example.com commit -qm "Initial shop"
