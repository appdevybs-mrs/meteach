<?php
declare(strict_types=1);

use Kreait\Firebase\Factory;

require_once __DIR__ . '/vendor/autoload.php';

header('Content-Type: application/json; charset=utf-8');

$results = [];

// --- 1. Environment variables ---
$results['env']['GOOGLE_APPLICATION_CREDENTIALS'] = getenv('GOOGLE_APPLICATION_CREDENTIALS') ?: '(not set)';
$results['env']['FIREBASE_DB_URL'] = getenv('FIREBASE_DB_URL') ?: '(not set)';

// --- 2. secure_config.php ---
$cfgPath = __DIR__ . '/secure_config.php';
$results['secure_config']['path'] = $cfgPath;
$results['secure_config']['exists'] = is_file($cfgPath);
$results['secure_config']['readable'] = is_readable($cfgPath);

if (is_file($cfgPath) && is_readable($cfgPath)) {
    $cfg = include $cfgPath;
    if (is_array($cfg)) {
        $results['secure_config']['GOOGLE_APPLICATION_CREDENTIALS'] = isset($cfg['GOOGLE_APPLICATION_CREDENTIALS']) ? '(set)' : '(missing)';
        $results['secure_config']['FIREBASE_DB_URL'] = isset($cfg['FIREBASE_DB_URL']) ? '(set)' : '(missing)';
    } else {
        $results['secure_config']['error'] = 'secure_config.php did not return an array';
    }
}

// --- 3. Determine effective credentials and dbUrl ---
$credentials = getenv('GOOGLE_APPLICATION_CREDENTIALS');
$dbUrl = getenv('FIREBASE_DB_URL');

$credentials = is_string($credentials) ? trim($credentials) : '';
$dbUrl = is_string($dbUrl) ? trim($dbUrl) : '';

if ($credentials === '' || $dbUrl === '') {
    if (is_file($cfgPath) && is_readable($cfgPath)) {
        try {
            $cfg = include $cfgPath;
            if (is_array($cfg)) {
                if ($credentials === '') {
                    $v = $cfg['GOOGLE_APPLICATION_CREDENTIALS'] ?? '';
                    if (is_string($v) && trim($v) !== '') {
                        $credentials = trim($v);
                    }
                }
                if ($dbUrl === '') {
                    $v = $cfg['FIREBASE_DB_URL'] ?? '';
                    if (is_string($v) && trim($v) !== '') {
                        $dbUrl = trim($v);
                    }
                }
            }
        } catch (Throwable $e) {
            $results['secure_config']['load_error'] = $e->getMessage();
        }
    }
}

$results['effective']['credentials_set'] = $credentials !== '';
$results['effective']['credentials_path'] = $credentials;
$results['effective']['dbUrl_set'] = $dbUrl !== '';
$results['effective']['dbUrl'] = $dbUrl;

// --- 4. Test credentials file exists ---
$results['test']['creds_file_exists'] = is_file($credentials);
$results['test']['creds_file_readable'] = is_readable($credentials);

// --- 5. DNS resolution ---
if ($dbUrl !== '') {
    $host = parse_url($dbUrl, PHP_URL_HOST);
    $ip = gethostbyname($host);
    $results['test']['dns']['host'] = $host;
    $results['test']['dns']['resolved_ip'] = $ip;
    $results['test']['dns']['resolved'] = $ip !== $host;
} else {
    $results['test']['dns']['error'] = 'Cannot resolve: dbUrl is empty';
}

// --- 6. Test Firebase factory creation ---
if ($credentials === '' || $dbUrl === '') {
    $results['test']['factory'] = 'SKIPPED: missing credentials or dbUrl';
} else {
    try {
        $factory = (new Factory())
            ->withServiceAccount($credentials)
            ->withDatabaseUri($dbUrl);
        $results['test']['factory'] = 'OK';
    } catch (Throwable $e) {
        $results['test']['factory'] = 'FAILED: ' . $e->getMessage();
    }
}

// --- 7. Test database read ---
if (!isset($factory)) {
    $results['test']['database_read'] = 'SKIPPED: factory not created';
} else {
    try {
        $val = $factory->createDatabase()->getReference('appConfig/appVersion')->getValue();
        if ($val !== null) {
            $results['test']['database_read'] = 'OK (read appConfig successfully)';
        } else {
            $results['test']['database_read'] = 'OK (connected, appConfig is null)';
        }
    } catch (Throwable $e) {
        $results['test']['database_read'] = 'FAILED: ' . $e->getMessage();
    }
}

// --- 8. Test reading a real user role ---
if (!isset($factory)) {
    $results['test']['role_read'] = 'SKIPPED: factory not created';
} else {
    $uid = $_GET['uid'] ?? '';
    if ($uid === '') {
        $results['test']['role_read'] = 'SKIPPED: pass ?uid=XXX to test a specific user';
    } else {
        try {
            $roleVal = $factory->createDatabase()->getReference('users/' . $uid . '/role')->getValue();
            $results['test']['role_read'] = ['uid' => $uid, 'role' => $roleVal];
        } catch (Throwable $e) {
            $results['test']['role_read'] = 'FAILED: ' . $e->getMessage();
        }
    }
}

// --- 9. PHP info ---
$results['php']['version'] = PHP_VERSION;
$results['php']['sapi'] = PHP_SAPI;
$results['php']['functions'] = [
    'getallheaders' => function_exists('getallheaders'),
    'curl' => function_exists('curl_version'),
    'openssl' => extension_loaded('openssl'),
];

echo json_encode($results, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES);
