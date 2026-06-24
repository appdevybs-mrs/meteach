<?php
declare(strict_types=1);

require_once __DIR__ . '/bootstrap.php';

const ALLOWED_ROOTS = ['courses', 'games', 'stories', 'shared_files', 'certificates', 'splash'];

function storage_root_dir(): string
{
    $root = getenv('YBS_STORAGE_DIR');
    if (!is_string($root) || trim($root) === '') {
        $candidateAppStorage = dirname(__DIR__) . '/storage';
        if (is_dir(dirname($candidateAppStorage))) {
            $root = $candidateAppStorage;
        }
    }

    if (!is_string($root) || trim($root) === '') {
        $docRoot = $_SERVER['DOCUMENT_ROOT'] ?? '';
        if (is_string($docRoot) && trim($docRoot) !== '' && is_dir($docRoot)) {
            $root = $docRoot;
        } else {
            // Legacy deployment fallback: /public_html/app/secure -> /public_html
            $candidatePublic = dirname(__DIR__, 2);
            if (is_dir($candidatePublic)) {
                $root = $candidatePublic;
            } else {
                $root = __DIR__ . '/../public_assets';
            }
        }
    }
    if (!is_dir($root) && !mkdir($root, 0775, true) && !is_dir($root)) {
        json_response(['success' => false, 'message' => 'Cannot initialize storage root.'], 500);
    }
    return rtrim($root, '/');
}

function public_base_url(): string
{
    $base = getenv('YBS_PUBLIC_BASE_URL');
    if (!is_string($base) || trim($base) === '') {
        $base = 'https://api.yourbridgeschool.com/apps/your-bridge-school/storage';
    }
    return rtrim($base, '/');
}

function resolve_target_path(string $root, string $path = ''): array
{
    $root = strtolower(trim($root));
    if (!in_array($root, ALLOWED_ROOTS, true)) {
        json_response(['success' => false, 'message' => 'Invalid root.'], 400);
    }

    $clean = sanitize_rel_path($path);
    $base = storage_root_dir() . '/' . $root;
    if (!is_dir($base) && !mkdir($base, 0775, true) && !is_dir($base)) {
        json_response(['success' => false, 'message' => 'Cannot create root folder.'], 500);
    }

    $full = $clean === '' ? $base : ($base . '/' . $clean);
    return ['root' => $root, 'clean' => $clean, 'base' => $base, 'full' => $full];
}

function build_public_url(string $root, string $cleanPath): string
{
    $encoded = implode('/', array_map('rawurlencode', array_filter(explode('/', $cleanPath))));
    $prefix = public_base_url() . '/' . rawurlencode($root);
    return $encoded === '' ? $prefix : ($prefix . '/' . $encoded);
}

function ensure_parent_dir(string $path): void
{
    if (is_dir($path)) {
        return;
    }
    if (!mkdir($path, 0775, true) && !is_dir($path)) {
        json_response(['success' => false, 'message' => 'Cannot create directory.'], 500);
    }
}
