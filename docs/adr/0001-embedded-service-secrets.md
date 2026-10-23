# Embed service API secrets in the app, masked, rather than run a signing proxy

Publishing to Flickr (RAW-173) signs every request with the app's Flickr API key and secret. Flickr's API uses OAuth
1.0a, which has no flow for public clients like PKCE: whoever signs requests needs the consumer secret. So a desktop
app can either ship the secret, or send each request through a server we run that holds it and signs for us.

We ship it. Scripts/generate-secrets.sh runs as the PixelLoupe target's first build phase and writes the values as
Swift byte arrays XORed with a mask (`Secrets.flickrKey`, `Secrets.flickrSecret`), so they aren't plain strings in the
binary or the bundle. It reads them from the environment, which the release workflow sets from repository secrets,
or from the gitignored .env for local builds. Without them the app still builds, and Flickr says it's unavailable.

## Considered options

- **Masked in the binary (chosen).** No server to run, pay for or keep up; this is what most desktop Flickr clients
  do. Anyone determined can recover the secret with a debugger. The worst they can do with it is make API calls
  that look like PixelLoupe's, which could get the key rate-limited or revoked. If that happens, we issue a new
  key and ship an update.
- **A signing proxy.** The secret never leaves our server, but every Flickr call depends on a service we'd have to
  host, secure and keep running for every installed copy. That's not worth it for a key with this little at stake.
- **The plain .env file in the bundle.** This is what commit 9c57fe2 did, by adding .env to the Xcode project's
  resources. Anyone could read it in Finder, and since Scripts/setup-release-secrets.sh also saves release signing
  secrets to .env, those could have been shipped too. The generator only reads the names it knows, and .env is
  not part of the Xcode project.

## Consequences

- The PixelLoupe target turns off user script sandboxing (`ENABLE_USER_SCRIPT_SANDBOXING = NO`). A sandboxed phase
  must declare .env as an input, and the build fails when a declared input is missing. That would break every
  clone without .env, and CI. The phase is the target's only script.
- The phase runs on every build, but rewrites its output only when a value changes, because the mask is derived
  from the value. Unchanged values don't recompile anything.
- Releases need the `FLICKR_KEY` and `FLICKR_SECRET` repository secrets. Until Flickr publishing ships, the release
  workflow only warns when they're missing.
