"""Manifest repository for managed artifacts."""

from __future__ import annotations

import json
from pathlib import Path
import uuid

from mcp.core.models import ArtifactReference, utc_now
from mcp.core.serialization import sha256_text, to_primitive
from .filesystem import FileSystem
from .paths import RuntimePaths


class ManifestRepository:
    """Persist and update the subsystem manifest."""

    def __init__(
        self,
        paths: RuntimePaths,
        filesystem: FileSystem | None = None,
        subsystem_version: str = "0.1.0",
    ) -> None:
        self._paths = paths
        self._filesystem = filesystem or FileSystem()
        self._subsystem_version = subsystem_version

    def _empty_manifest(self) -> dict:
        now = utc_now()
        return {
            "schema_version": "1",
            "runtime_root": str(self._paths.runtime_root),
            "created_at": now,
            "updated_at": now,
            "subsystem_version": self._subsystem_version,
            "artifacts": [],
            "snapshots": [],
        }

    def load(self) -> dict:
        self._paths.ensure()
        if not self._paths.manifest_path.exists():
            return self._empty_manifest()
        return self._filesystem.read_json(self._paths.manifest_path)

    def save(self, manifest: dict) -> None:
        manifest["updated_at"] = utc_now()
        content = json.dumps(manifest, indent=2, sort_keys=True)
        self._filesystem.write_text(self._paths.manifest_path, content + "\n")

    def list_active_artifacts(self) -> list[dict]:
        return [
            artifact
            for artifact in self.load()["artifacts"]
            if artifact.get("removed_at") is None
        ]

    def manifest_hash(self) -> str:
        manifest = self.load()
        return sha256_text(json.dumps(manifest, sort_keys=True))

    def upsert_artifact(self, artifact: ArtifactReference) -> ArtifactReference:
        manifest = self.load()
        artifacts = manifest["artifacts"]
        now = utc_now()
        record = to_primitive(artifact)
        if not record.get("artifact_id"):
            record["artifact_id"] = str(uuid.uuid4())
        for existing in artifacts:
            if existing.get("removed_at") is not None:
                continue
            same_identity = (
                existing["client"] == record["client"]
                and existing["path"] == record["path"]
                and existing.get("metadata", {}).get("entry_name")
                == record.get("metadata", {}).get("entry_name")
            )
            if same_identity:
                record["artifact_id"] = existing["artifact_id"]
                record["created_at"] = existing.get("created_at") or now
                record["updated_at"] = now
                record["removed_at"] = None
                existing.update(record)
                self.save(manifest)
                return ArtifactReference(**existing)
        record["created_at"] = record.get("created_at") or now
        record["updated_at"] = now
        artifacts.append(record)
        self.save(manifest)
        return ArtifactReference(**record)

    def mark_removed(self, artifact_id: str) -> None:
        manifest = self.load()
        for artifact in manifest["artifacts"]:
            if artifact["artifact_id"] == artifact_id and artifact.get("removed_at") is None:
                artifact["removed_at"] = utc_now()
                artifact["updated_at"] = artifact["removed_at"]
        self.save(manifest)

    def add_snapshot(self, snapshot_record: dict) -> None:
        manifest = self.load()
        manifest["snapshots"].append(snapshot_record)
        self.save(manifest)

    def latest_snapshot_id(self) -> str | None:
        manifest = self.load()
        snapshots = manifest.get("snapshots", [])
        if not snapshots:
            return None
        return snapshots[-1]["snapshot_id"]
