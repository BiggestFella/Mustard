# Create the GitHub repo (one-time)

The cloud agent cannot create repos on `ch-leon` — run this on your Mac:

```bash
# 1. Create empty private repo
gh repo create ch-leon/Yell --private --description "Yell — satirical Mac dictation + listen-aloud. Don't whisper."

# 2. Copy this scaffold (from Mustard export branch or clone)
git clone https://github.com/ch-leon/Yell.git ~/Developer/Yell
cp -R yell-scaffold-export/* ~/Developer/Yell/   # adjust source path

# 3. Initial push
cd ~/Developer/Yell
git add -A
git commit -m "chore: initial Yell repo skeleton"
git push -u origin main
```

Then update Notion **Repo** field to `https://github.com/ch-leon/Yell`.

This folder lives temporarily on branch `cursor/yell-repo-scaffold-7dff` in Mustard — **do not merge**; delete the branch after Yell repo exists.
