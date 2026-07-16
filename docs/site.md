# nckslvr.mn

A static site built with [Hugo](https://gohugo.io/) + the
[PaperMod](https://github.com/adityatelange/hugo-PaperMod) theme, deployed to
GitHub Pages via GitHub Actions on every push to `main`.

## Reference

### Resume

The resume at `/resume/` is rendered at build time from `data/resume.json` via
`layouts/resume.html` — edit the JSON to update it. The deploy workflow also
prints it to `/resume.pdf` with headless Chrome (`scripts/build-resume-pdf.sh`),
regenerating only when resume sources change. Schema concept inspired by
[jsonresume](https://jsonresume.org/), original theme inspired by
[kwan](https://github.com/icoloma/jsonresume-theme-kwan).

### New post

```bash
hugo new content posts/my-post/index.md
```

### Local preview

```bash
if [ -n "$CODESPACE_NAME" ]; then
  hugo server -D \
    --baseURL "https://${CODESPACE_NAME}-1313.${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN}/" \
    --appendPort=false \
    --liveReloadPort=443
else
  hugo server -D
fi
```

### Images

- **Per-post (recommended):** put the image in the post's folder and reference
  it by filename: `![alt](my-image.jpg)`
- **Shared:** put it in `static/images/` and reference it as `/images/foo.jpg`
