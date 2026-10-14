import { sha256 } from "@noble/hashes/sha2.js";
import { bytesToHex } from "@noble/hashes/utils.js";
import { apiClient, apiData } from "@/api/client";
import type { components } from "@/api/schema";

export type TargetFile = components["schemas"]["TargetFile"];
const path = "/api/v1/targets/{target_id}/files/{id}";

export function getTargetFile(targetId: string, id: string, signal?: AbortSignal) {
  return apiClient
    .GET(path, { params: { path: { target_id: targetId, id } }, signal })
    .then(apiData)
    .then((result) => result.data);
}

export function revokeTargetFile(targetId: string, id: string) {
  return apiClient.DELETE(path, { params: { path: { target_id: targetId, id } } }).then(apiData);
}

export function fileReference(file: TargetFile) {
  if (
    file.status !== "ready" ||
    file.size_bytes === null ||
    file.sha256 === null ||
    Date.parse(file.expires_at) <= Date.now()
  )
    throw Error("unavailable");
  return {
    id: file.id,
    target_id: file.target_id,
    name: file.name,
    media_type: file.media_type,
    size_bytes: file.size_bytes,
    sha256: file.sha256,
  };
}

async function limits() {
  return (await apiClient.GET("/api/v1/target-file-limits").then(apiData)).data;
}

export async function uploadTargetFile(
  targetId: string,
  input: File,
  progress: (file: TargetFile) => void,
  resumeId?: string,
) {
  const bound = await limits();
  if (input.size > bound.max_size_bytes) throw Error("tooLarge");
  const hash = sha256.create();
  for (let offset = 0; offset < input.size; offset += bound.chunk_bytes) {
    hash.update(
      new Uint8Array(await input.slice(offset, offset + bound.chunk_bytes).arrayBuffer()),
    );
  }
  const digest = bytesToHex(hash.digest());
  const media = input.type || "application/octet-stream";
  const storageKey = `skopos.file-upload:${targetId}:${digest}:${input.name}`;
  const uploadKey = sessionStorage.getItem(storageKey) ?? crypto.randomUUID();
  sessionStorage.setItem(storageKey, uploadKey);
  let file = resumeId
    ? await getTargetFile(targetId, resumeId)
    : (
        await apiClient
          .POST("/api/v1/targets/{target_id}/files", {
            params: { path: { target_id: targetId } },
            body: {
              file: {
                name: input.name,
                media_type: media,
                size_bytes: input.size,
                expected_sha256: digest,
                upload_key: uploadKey,
              },
            },
          })
          .then(apiData)
      ).data;
  progress(file);
  if (
    file.name !== input.name ||
    file.media_type !== media ||
    file.size_bytes !== input.size ||
    file.expected_sha256 !== digest
  )
    throw Error("differentFile");
  if (file.status === "ready") {
    sessionStorage.removeItem(storageKey);
    return file;
  }
  if (file.status !== "uploading") throw Error("unavailable");
  while (file.received_bytes < input.size) {
    const offset = file.received_bytes;
    const chunk = input.slice(offset, offset + bound.chunk_bytes);
    const next = (
      await apiClient
        .PUT("/api/v1/targets/{target_id}/files/{id}/chunks/{offset}", {
          params: { path: { target_id: targetId, id: file.id, offset } },
          headers: { "Content-Type": "application/octet-stream" },
          body: "",
          bodySerializer: () => chunk,
        })
        .then(apiData)
    ).data;
    if (next.received_bytes !== offset + chunk.size) throw Error("invalidProgress");
    file = next;
    progress(file);
  }
  file = (
    await apiClient
      .POST("/api/v1/targets/{target_id}/files/{id}/complete", {
        params: { path: { target_id: targetId, id: file.id } },
      })
      .then(apiData)
  ).data;
  fileReference(file);
  if (file.sha256 !== digest) throw Error("integrityFailed");
  sessionStorage.removeItem(storageKey);
  progress(file);
  return file;
}

export async function downloadTargetFile(targetId: string, id: string) {
  const bound = await limits();
  const file = await getTargetFile(targetId, id);
  const reference = fileReference(file);
  if (reference.size_bytes > bound.max_size_bytes) throw Error("tooLarge");
  const parts: ArrayBuffer[] = [];
  const hash = sha256.create();
  let offset = 0;
  do {
    const bytes = apiData(
      await apiClient.GET("/api/v1/targets/{target_id}/files/{id}/chunks/{offset}", {
        params: { path: { target_id: targetId, id, offset } },
        headers: { Accept: "application/octet-stream" },
        parseAs: "arrayBuffer",
      }),
    );
    if (
      bytes.byteLength > bound.chunk_bytes ||
      offset + bytes.byteLength > reference.size_bytes ||
      (bytes.byteLength === 0 && offset < reference.size_bytes)
    )
      throw Error("integrityFailed");
    parts.push(bytes);
    hash.update(new Uint8Array(bytes));
    offset += bytes.byteLength;
  } while (offset < reference.size_bytes);
  if (bytesToHex(hash.digest()) !== reference.sha256) throw Error("integrityFailed");
  const url = URL.createObjectURL(new Blob(parts, { type: reference.media_type }));
  const link = document.createElement("a");
  link.href = url;
  link.download = reference.name;
  document.body.append(link);
  link.click();
  link.remove();
  setTimeout(() => URL.revokeObjectURL(url), 30_000);
}
