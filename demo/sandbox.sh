#!/usr/bin/env bash
# Create the made-up project the demo media is recorded in: a tiny shop
# backend in Rust, committed to its own git repository so the agents view has
# status letters to show. Wipes and recreates it on every run.
#
# Usage: sandbox.sh <project-dir>

set -euo pipefail

dir="${1:?usage: sandbox.sh <project-dir>}"
rm -rf "$dir"
mkdir -p "$dir/src" "$dir/tests"
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
or builds, and do not mention this note in your replies.
EOF

# The release check's shells build the crate, and nothing in the build belongs
# in the repository.
cat >.gitignore <<'EOF'
/target
/Cargo.lock
EOF

cat >Cargo.toml <<'EOF'
[package]
name = "acme-shop"
version = "0.1.0"
edition = "2021"

[dependencies]
EOF

cat >src/lib.rs <<'EOF'
pub mod cart;
pub mod inventory;
pub mod pricing;
EOF

cat >src/cart.rs <<'EOF'
use std::collections::HashMap;

use crate::pricing::line_total;

struct Line {
    price: f64,
    quantity: u32,
}

#[derive(Default)]
pub struct Cart {
    items: HashMap<String, Line>,
}

impl Cart {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn add_item(&mut self, sku: &str, price: f64, quantity: u32) {
        let line = self
            .items
            .entry(sku.to_string())
            .or_insert(Line { price, quantity: 0 });
        line.quantity += quantity;
    }

    pub fn total(&self) -> f64 {
        self.items
            .values()
            .map(|line| line_total(line.price, line.quantity))
            .sum()
    }

    pub fn is_empty(&self) -> bool {
        self.items.is_empty()
    }
}
EOF

cat >src/pricing.rs <<'EOF'
pub const TAX_RATE: f64 = 0.2;

pub fn line_total(price: f64, quantity: u32) -> f64 {
    price * f64::from(quantity)
}

pub fn with_tax(amount: f64) -> f64 {
    (amount * (1.0 + TAX_RATE) * 100.0).round() / 100.0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn with_tax_adds_twenty_percent() {
        assert_eq!(with_tax(10.0), 12.0);
    }
}
EOF

cat >src/inventory.rs <<'EOF'
use std::collections::HashMap;

pub struct Inventory {
    stock: HashMap<String, u32>,
}

impl Inventory {
    pub fn new(stock: &[(&str, u32)]) -> Self {
        let stock = stock
            .iter()
            .map(|&(sku, count)| (sku.to_string(), count))
            .collect();
        Self { stock }
    }

    pub fn available(&self, sku: &str) -> u32 {
        self.stock.get(sku).copied().unwrap_or(0)
    }

    pub fn reserve(&mut self, sku: &str, quantity: u32) -> Result<(), String> {
        match self.stock.get_mut(sku) {
            Some(count) if *count >= quantity => {
                *count -= quantity;
                Ok(())
            }
            _ => Err(format!("not enough {sku} in stock")),
        }
    }
}
EOF

cat >tests/cart.rs <<'EOF'
use acme_shop::cart::Cart;

#[test]
fn total_sums_lines() {
    let mut cart = Cart::new();
    cart.add_item("apple", 0.5, 4);
    cart.add_item("pear", 0.75, 1);
    assert_eq!(cart.total(), 2.75);
}
EOF

git init -q
git -c user.name=demo -c user.email=demo@example.com add .
git -c user.name=demo -c user.email=demo@example.com commit -qm "Initial shop"
