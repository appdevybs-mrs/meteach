<?php
declare(strict_types=1);

require_once __DIR__ . '/file_ops.php';

require_auth(['admin', 'teacher']);

const MAX_UPLOAD_BYTES = 250 * 1024 * 1024;
const ALLOWED_EXTENSIONS = [
    'jpg', 'jpeg', 'png', 'webp', 'gif',
    'mp4', 'm4v', 'mov', 'webm',
    'mp3', 'm4a', 'wav',
    'pdf', 'doc', 'docx', 'ppt', 'pptx', 'xls', 'xlsx', 'txt', 'zip',
    'html', 'htm',
];

function parse_size_to_bytes(string $raw): int
{
    $v = trim($raw);
    if ($v === '') {
        return 0;
    }

    if (!preg_match('/^\s*(\d+(?:\.\d+)?)\s*([KMGTP]?)(?:B)?\s*$/i', $v, $m)) {
        return 0;
    }

    $num = (float) ($m[1] ?? '0');
    $unit = strtoupper((string) ($m[2] ?? ''));
    $mult = 1;
    if ($unit === 'K') {
        $mult = 1024;
    } elseif ($unit === 'M') {
        $mult = 1024 * 1024;
    } elseif ($unit === 'G') {
        $mult = 1024 * 1024 * 1024;
    } elseif ($unit === 'T') {
        $mult = 1024 * 1024 * 1024 * 1024;
    } elseif ($unit === 'P') {
        $mult = 1024 * 1024 * 1024 * 1024 * 1024;
    }

    return (int) floor($num * $mult);
}

function effective_upload_limit_bytes(): int
{
    $candidates = [MAX_UPLOAD_BYTES];
    $uploadMax = parse_size_to_bytes((string) ini_get('upload_max_filesize'));
    $postMax = parse_size_to_bytes((string) ini_get('post_max_size'));
    if ($uploadMax > 0) {
        $candidates[] = $uploadMax;
    }
    if ($postMax > 0) {
        $candidates[] = $postMax;
    }
    return min($candidates);
}

if (!isset($_FILES['file']) || !is_array($_FILES['file'])) {
    json_response(['success' => false, 'message' => 'Missing file.'], 400);
}

$uploadErr = (int) ($_FILES['file']['error'] ?? UPLOAD_ERR_OK);
if ($uploadErr !== UPLOAD_ERR_OK) {
    $effectiveLimit = effective_upload_limit_bytes();
    $effectiveLimitMb = (int) floor($effectiveLimit / (1024 * 1024));
    $message = 'Upload failed.';
    $status = 400;
    if ($uploadErr === UPLOAD_ERR_INI_SIZE || $uploadErr === UPLOAD_ERR_FORM_SIZE) {
        $message = 'File exceeds server upload limit (' . $effectiveLimitMb . ' MB).';
        $status = 413;
    } elseif ($uploadErr === UPLOAD_ERR_PARTIAL) {
        $message = 'Upload was interrupted. Please retry.';
    } elseif ($uploadErr === UPLOAD_ERR_NO_FILE) {
        $message = 'Missing file.';
    } elseif ($uploadErr === UPLOAD_ERR_NO_TMP_DIR) {
        $message = 'Server missing temp upload directory.';
        $status = 500;
    } elseif ($uploadErr === UPLOAD_ERR_CANT_WRITE) {
        $message = 'Server could not write uploaded file.';
        $status = 500;
    } elseif ($uploadErr === UPLOAD_ERR_EXTENSION) {
        $message = 'Upload blocked by server extension.';
        $status = 500;
    }
    json_response([
        'success' => false,
        'message' => $message,
        'upload_error_code' => $uploadErr,
        'max_upload_bytes' => MAX_UPLOAD_BYTES,
        'effective_limit_bytes' => $effectiveLimit,
        'upload_max_filesize' => (string) ini_get('upload_max_filesize'),
        'post_max_size' => (string) ini_get('post_max_size'),
    ], $status);
}

$root = (string) ($_POST['root'] ?? '');
$path = (string) ($_POST['path'] ?? '');
$customName = sanitize_segment((string) ($_POST['custom_name'] ?? ''));

$resolved = resolve_target_path($root, $path);
ensure_parent_dir($resolved['full']);

$tmp = (string) ($_FILES['file']['tmp_name'] ?? '');
if ($tmp === '' || !is_uploaded_file($tmp)) {
    json_response(['success' => false, 'message' => 'Invalid uploaded file.'], 400);
}

$size = (int) ($_FILES['file']['size'] ?? 0);
$effectiveLimit = effective_upload_limit_bytes();
if ($size <= 0 || $size > $effectiveLimit) {
    json_response([
        'success' => false,
        'message' => 'File exceeds server upload limit (' . (int) floor($effectiveLimit / (1024 * 1024)) . ' MB).',
        'max_upload_bytes' => MAX_UPLOAD_BYTES,
        'effective_limit_bytes' => $effectiveLimit,
        'upload_max_filesize' => (string) ini_get('upload_max_filesize'),
        'post_max_size' => (string) ini_get('post_max_size'),
        'received_size_bytes' => $size,
    ], 413);
}

$origName = (string) ($_FILES['file']['name'] ?? 'file.bin');
$base = $customName !== '' ? $customName : sanitize_segment(pathinfo($origName, PATHINFO_FILENAME));
if ($base === '') {
    $base = 'file';
}

$ext = strtolower((string) pathinfo($origName, PATHINFO_EXTENSION));
$safeExt = $ext === '' ? '' : sanitize_segment($ext);
if ($safeExt === '' || !in_array($safeExt, ALLOWED_EXTENSIONS, true)) {
    json_response(['success' => false, 'message' => 'File type not allowed.'], 400);
}
$finalName = $base . '_' . bin2hex(random_bytes(5)) . '.' . $safeExt;
$target = $resolved['full'] . '/' . $finalName;

if (!move_uploaded_file($tmp, $target)) {
    json_response(['success' => false, 'message' => 'Move upload failed.'], 500);
}

$rel = trim($resolved['clean'] . '/' . $finalName, '/');
$url = build_public_url($resolved['root'], $rel);

json_response(['success' => true, 'url' => $url]);
