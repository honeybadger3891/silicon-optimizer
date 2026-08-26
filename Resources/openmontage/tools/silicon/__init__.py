"""Silicon Optimizer as an OpenMontage provider.

Three tools — images, video, 3D — each a thin HTTP client for the Silicon Optimizer
app running on this Mac. The app does the work on hardware you own: images on this
Mac's GPU, video on a paired Windows node, meshes on whichever can. Nothing here
costs money, sends a prompt to a vendor, or needs an API key.

Dropped into an OpenMontage checkout as ``tools/silicon/`` by the app's own
"Set up OpenMontage" button, or by hand: copy this directory there and the
registry picks it up on the next ``discover()``.
"""
