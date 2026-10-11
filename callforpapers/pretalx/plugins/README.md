# pretalx plugins

## `cndfr_speaker_gate`

pretalx checks required speaker fields (custom fields "per speaker", biography,
photo) only when someone saves the form that holds them. A co-speaker who accepts
an invitation never goes through the CfP wizard, so nothing makes them fill those
fields in. When enabled for an event, this plugin:

- **refuses to confirm a proposal** while one of its speakers has a required field
  left empty, and names who is missing what. This applies to the speaker's
  "Confirm" button, the organiser's, and the API. Accepting is not gated: the
  review dashboard's accept action does not handle a refusal and would return a
  500 error.
- **shows a banner** on "Your proposals" and "Your profile" listing the fields
  that are still missing, with a link to the profile.

A required checkbox (e.g. a consent) only counts once it is ticked.

### Deployment

There is no custom image. `kustomization.yaml` turns the plugin files into the
`pretalx-plugins` ConfigMap; `statefulset.yaml` mounts it on `/plugins` and sets
`PYTHONPATH=/plugins`. pretalx finds the plugin through the `pretalx.plugin`
entry point in `cndfr_speaker_gate.dist-info/`.

A deployed plugin does nothing until an organiser enables it for an event under
**Settings → Plugins**.

Adding a file to the plugin means listing it in both the `configMapGenerator`
and the volume `items` (ConfigMap keys cannot contain `/`).

### Tests

```sh
./run-tests.sh            # add any pytest arguments, e.g. -k banner
```

The script clones the pretalx release pinned in `../statefulset.yaml`, installs
it with `uv`, and runs the tests with pretalx's own test settings and factories.
CI runs it (`.github/workflows/pretalx-plugin.yaml`) on every change under
`callforpapers/pretalx/`, so a Renovate bump of the image tag is tested against
the new pretalx before it is merged.
