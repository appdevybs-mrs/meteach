<?php
declare(strict_types=1);

require_once __DIR__ . '/file_ops.php';

require_auth(['admin', 'teacher']);

$root = trim((string) ($_POST['root'] ?? $_GET['root'] ?? ''));
$path = trim((string) ($_POST['path'] ?? $_GET['path'] ?? ''));
$expect = strtolower(trim((string) ($_POST['expect'] ?? $_GET['expect'] ?? '')));

if ($root === '' || $path === '') {
    json_response(['success' => false, 'message' => 'Missing root/path.'], 400);
}

if ($expect !== '' && $expect !== 'file' && $expect !== 'folder') {
    json_response(['success' => false, 'message' => 'Invalid expect.'], 400);
}

$resolved = resolve_target_path($root, $path);
$full = $resolved['full'];

$isFile = is_file($full);
$isFolder = is_dir($full);
$exists = $isFile || $isFolder;

$matchesExpect = true;
if ($expect === 'file') {
    $matchesExpect = $isFile;
} elseif ($expect === 'folder') {
    $matchesExpect = $isFolder;
}

$type = 'missing';
if ($isFile) {
    $type = 'file';
} elseif ($isFolder) {
    $type = 'folder';
}

json_response([
    'success' => true,
    'exists' => $exists && $matchesExpect,
    'type' => $type,
    'expect' => $expect,
    'path' => $resolved['clean'],
]);
