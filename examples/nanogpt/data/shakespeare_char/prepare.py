"""
Download and prepare TinyShakespeare for character-level training.

Usage:
    python prepare.py

Creates train.pt and val.pt (90/10 split) plus meta.json with vocab info.
"""

import json
import os
import urllib.request

DATA_URL = "https://raw.githubusercontent.com/karpathy/char-rnn/master/data/tinyshakespeare/input.txt"
LOCAL_DIR = os.path.dirname(os.path.abspath(__file__))


def main():
    input_path = os.path.join(LOCAL_DIR, "input.txt")

    if not os.path.exists(input_path):
        print(f"Downloading TinyShakespeare to {input_path} ...")
        urllib.request.urlretrieve(DATA_URL, input_path)
    else:
        print(f"Found {input_path}, skipping download.")

    with open(input_path, "r") as f:
        text = f.read()

    print(f"Text length: {len(text):,} characters")

    chars = sorted(set(text))
    vocab_size = len(chars)
    print(f"Vocab size: {vocab_size} unique characters")

    stoi = {ch: i for i, ch in enumerate(chars)}
    itos = {i: ch for i, ch in enumerate(chars)}

    import torch

    data = torch.tensor([stoi[ch] for ch in text], dtype=torch.int64)

    n = len(data)
    split = int(n * 0.9)
    train_data = data[:split]
    val_data = data[split:]

    print(f"Train: {len(train_data):,} tokens, Val: {len(val_data):,} tokens")

    torch.save(train_data, os.path.join(LOCAL_DIR, "train.pt"))
    torch.save(val_data, os.path.join(LOCAL_DIR, "val.pt"))

    meta = {
        "vocab_size": vocab_size,
        "itos": itos,
        "stoi": stoi,
    }
    with open(os.path.join(LOCAL_DIR, "meta.json"), "w") as f:
        json.dump(meta, f, indent=2)

    print("Done! Created train.pt, val.pt, meta.json")


if __name__ == "__main__":
    main()
