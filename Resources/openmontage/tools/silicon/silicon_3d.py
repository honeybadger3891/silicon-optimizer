"""A picture into a mesh, through Silicon Optimizer.

Image-to-3D only. The app has no text-to-3D model — it makes the picture first, with
``silicon_image``, then the mesh from that — so ``operation`` accepts one value and
the schema says so rather than advertising a path that would fail.
"""

from __future__ import annotations

import time
from typing import Any

from tools.base_tool import (
    BaseTool,
    Determinism,
    ExecutionMode,
    ResourceProfile,
    RetryPolicy,
    ToolResult,
    ToolRuntime,
    ToolStability,
    ToolStatus,
    ToolTier,
)
from tools.silicon import _client


class Silicon3D(BaseTool):
    name = "silicon_3d"
    version = "0.1.0"
    tier = ToolTier.GENERATE
    capability = "3d_asset_generation"
    provider = _client.PROVIDER
    stability = ToolStability.BETA
    execution_mode = ExecutionMode.SYNC
    determinism = Determinism.SEEDED
    runtime = ToolRuntime.LOCAL

    dependencies: list[str] = []
    install_instructions = (
        "Open Silicon Optimizer. Its 3D tab installs a mesh model on first use "
        "(Hunyuan3D on this Mac, or TRELLIS/LATO on a paired node)."
    )

    capabilities = ["image_to_3d", "textured_mesh", "low_poly_mesh", "offline_generation"]
    supports = {
        "text_to_3d": False,
        "image_to_3d": True,
        "textured_glb": True,
        "clean_obj": True,
        "offline": True,
    }
    best_for = [
        "a game-ready mesh from one hero still, for free",
        "props and characters that must stay on your own machines",
    ]
    not_good_for = [
        "text_to_3d in one step — render the picture with silicon_image first",
    ]

    input_schema = {
        "type": "object",
        "required": ["image_path", "output_path"],
        "properties": {
            "operation": {"type": "string", "enum": ["image_to_3d"], "default": "image_to_3d"},
            "image_path": {"type": "string"},
            "output_path": {"type": "string", "description": "Where the .glb goes."},
            "model": {"type": "string", "description": "An id from the app's 3D tab. Omit for its current choice."},
            "vertex_budget": {"type": "integer", "minimum": 200, "maximum": 5000, "description": "Low-poly target, when the model retopologises."},
            "texture_size": {"type": "integer", "description": "e.g. 1024 or 2048."},
            "seed": {"type": "integer"},
        },
    }

    resource_profile = ResourceProfile(cpu_cores=4, ram_mb=12288, vram_mb=0, disk_mb=100, network_required=False)
    retry_policy = RetryPolicy(max_retries=0)
    idempotency_key_fields = ["image_path", "model", "vertex_budget", "texture_size", "seed"]
    side_effects = ["writes a .glb (and .obj when the model makes one) to the app's output folder, and the .glb to output_path"]
    user_visible_verification = ["Open the .glb — the app's 3D tab shows it spinning"]

    def get_status(self) -> ToolStatus:
        return ToolStatus.AVAILABLE if _client.is_running() else ToolStatus.UNAVAILABLE

    def estimate_cost(self, inputs: dict[str, Any]) -> float:
        return 0.0

    def estimate_runtime(self, inputs: dict[str, Any]) -> float:
        return 120.0

    @staticmethod
    def request_body(inputs: dict[str, Any]) -> dict[str, Any]:
        """The app's MeshRequest, from OpenMontage's input names."""
        return _client.drop_none({
            "imagePath": inputs["image_path"],
            "modelID": inputs.get("model"),
            "vertexBudget": inputs.get("vertex_budget"),
            "textureSize": inputs.get("texture_size"),
            "seed": inputs.get("seed"),
        })

    def execute(self, inputs: dict[str, Any]) -> ToolResult:
        if inputs.get("operation", "image_to_3d") != "image_to_3d":
            return ToolResult(success=False, error="silicon_3d only does image_to_3d. Make the image with silicon_image first.")
        if not inputs.get("image_path"):
            return ToolResult(success=False, error="image_path is required")

        started = time.time()
        try:
            answer = _client.post("/mesh/generate", self.request_body(inputs), _client.MESH_TIMEOUT_SECONDS)
        except _client.SiliconUnavailable as exc:
            return ToolResult(success=False, error=f"{exc} {self.install_instructions}")
        except _client.SiliconError as exc:
            return ToolResult(success=False, error=str(exc))

        glb = answer.get("glbPath")
        obj = answer.get("objPath")
        if not glb and not obj:
            return ToolResult(success=False, error="The app reported success but returned no mesh.")

        primary = _client.deliver(glb or obj, inputs.get("output_path"))
        artifacts = [primary]
        if glb and obj:
            artifacts.append(obj)
        return ToolResult(
            success=True,
            data={
                "provider": self.provider,
                "model": answer.get("model"),
                "operation": "image_to_3d",
                "output": primary,
                "output_path": primary,
                "outputs": artifacts,
                "glb_path": primary if glb else None,
                "obj_path": obj,
                "elapsed_seconds": answer.get("elapsedSeconds"),
                "warning": answer.get("warning"),
            },
            artifacts=artifacts,
            cost_usd=0.0,
            duration_seconds=round(time.time() - started, 2),
            seed=inputs.get("seed"),
            model=answer.get("model"),
        )
