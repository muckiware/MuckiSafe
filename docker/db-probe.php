<?php

declare(strict_types=1);

/**
 * MuckiSafe database probe for docker/entrypoint.sh.
 *
 * Answers "what is in the database?" without booting the application kernel,
 * so a broken cache or a PHP error in the application can never be mistaken
 * for "not installed".
 *
 * Usage:  php db-probe.php tables|users
 *   tables  number of tables in the configured schema (0 = empty or missing)
 *   users   number of rows in `user` (0 if the table does not exist)
 *
 * Prints the number on stdout. Exit code 0 on success, 2 on usage or
 * configuration errors, 3 if the database server cannot be queried.
 */

const EXIT_USAGE = 2;
const EXIT_UNREACHABLE = 3;

function fail(int $code, string $message): never
{
    fwrite(\STDERR, '[db-probe] ' . $message . \PHP_EOL);

    exit($code);
}

/**
 * @return array{host: string, port: int, user: string, password: string, schema: string}
 */
function parseDatabaseUrl(string $url): array
{
    $parts = parse_url($url);

    if ($parts === false || !isset($parts['host'], $parts['path'])) {
        fail(EXIT_USAGE, 'DATABASE_URL is missing or malformed.');
    }

    $schema = rawurldecode(ltrim($parts['path'], '/'));

    if ($schema === '') {
        fail(EXIT_USAGE, 'DATABASE_URL does not name a database.');
    }

    return [
        'host' => $parts['host'],
        'port' => (int) ($parts['port'] ?? 3306),
        'user' => rawurldecode($parts['user'] ?? ''),
        'password' => rawurldecode($parts['pass'] ?? ''),
        'schema' => $schema,
    ];
}

function countTables(PDO $pdo, string $schema, ?string $table = null): int
{
    $sql = 'SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = ?';
    $params = [$schema];

    if ($table !== null) {
        $sql .= ' AND table_name = ?';
        $params[] = $table;
    }

    $statement = $pdo->prepare($sql);
    $statement->execute($params);

    return (int) $statement->fetchColumn();
}

function countUsers(PDO $pdo, string $schema): int
{
    if (countTables($pdo, $schema, 'user') === 0) {
        return 0;
    }

    $quoted = '`' . str_replace('`', '``', $schema) . '`';

    return (int) $pdo->query('SELECT COUNT(*) FROM ' . $quoted . '.`user`')->fetchColumn();
}

$mode = $argv[1] ?? '';

if (!\in_array($mode, ['tables', 'users'], true)) {
    fail(EXIT_USAGE, 'Usage: db-probe.php tables|users');
}

$config = parseDatabaseUrl((string) getenv('DATABASE_URL'));

try {
    // No dbname in the DSN: the schema may not exist yet on first boot.
    $pdo = new PDO(
        sprintf('mysql:host=%s;port=%d;charset=utf8mb4', $config['host'], $config['port']),
        $config['user'],
        $config['password'],
        [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION, PDO::ATTR_TIMEOUT => 5],
    );

    $count = $mode === 'tables'
        ? countTables($pdo, $config['schema'])
        : countUsers($pdo, $config['schema']);
} catch (PDOException $exception) {
    fail(EXIT_UNREACHABLE, 'Database query failed: ' . $exception->getMessage());
}

echo $count . \PHP_EOL;
