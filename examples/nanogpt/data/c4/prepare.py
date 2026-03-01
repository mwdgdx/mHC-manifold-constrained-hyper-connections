"""
Download and tokenize a subset of C4 for training.

Uses GPT-2 BPE tokenizer (tiktoken). Downloads from HuggingFace,
tokenizes, and saves as train.pt / val.pt.

Usage:
    python prepare.py              # default: ~100M train tokens (~800MB)
    python prepare.py 500          # ~500M train tokens (~4GB)
    python prepare.py 2000         # ~2B tokens (~16GB)

Requires: pip install datasets tiktoken
"""

import os
import sys

import tiktoken
import torch
from datasets import load_dataset

LOCAL_DIR = os.path.dirname(os.path.abspath(__file__))

TARGET_TRAIN_TOKENS = int(sys.argv[1]) * 1_000_000 if len(sys.argv) > 1 else 500_000_000
TARGET_VAL_TOKENS = 5_000_000  # 5M tokens for validation


def tokenize_split(dataset_iter, target_tokens, enc):
    """Tokenize documents until we have enough tokens."""
    all_tokens = []
    total = 0
    for doc in dataset_iter:
        tokens = enc.encode_ordinary(doc["text"])
        all_tokens.extend(tokens)
        total += len(tokens)
        if total % 10_000_000 < len(tokens):
            print(f"  {total / 1e6:.1f}M tokens collected...")
        if total >= target_tokens:
            break
    return torch.tensor(all_tokens[:target_tokens], dtype=torch.int64)


def main():
    print(f"Target: {TARGET_TRAIN_TOKENS / 1e6:.0f}M train tokens, "
          f"{TARGET_VAL_TOKENS / 1e6:.0f}M val tokens")

    enc = tiktoken.get_encoding("gpt2")
    print(f"Tokenizer: GPT-2 BPE (vocab_size={enc.n_vocab})")

    print("\nLoading C4 validation split (streaming)...")
    val_ds = load_dataset("allenai/c4", "en", split="validation", streaming=True)
    val_data = tokenize_split(val_ds, TARGET_VAL_TOKENS, enc)
    print(f"Val: {len(val_data):,} tokens")

    print("\nLoading C4 train split (streaming)...")
    train_ds = load_dataset("allenai/c4", "en", split="train", streaming=True)
    train_data = tokenize_split(train_ds, TARGET_TRAIN_TOKENS, enc)
    print(f"Train: {len(train_data):,} tokens")

    torch.save(train_data, os.path.join(LOCAL_DIR, "train.pt"))
    torch.save(val_data, os.path.join(LOCAL_DIR, "val.pt"))

    print(f"\nSaved to {LOCAL_DIR}/")
    print(f"  train.pt: {os.path.getsize(os.path.join(LOCAL_DIR, 'train.pt')) / 1e6:.1f} MB")
    print(f"  val.pt:   {os.path.getsize(os.path.join(LOCAL_DIR, 'val.pt')) / 1e6:.1f} MB")
    print("Done!")


if __name__ == "__main__":
    main()
