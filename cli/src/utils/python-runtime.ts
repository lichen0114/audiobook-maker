import { spawnSync } from 'child_process';
import * as fs from 'fs';
import * as path from 'path';

export interface PythonRuntime {
    projectRoot: string;
    appPath: string;
    pythonPath: string;
}

export function getProjectRoot(): string {
    return path.resolve(import.meta.dirname, '../../..');
}

export function getAppPath(projectRoot = getProjectRoot()): string {
    return path.join(projectRoot, 'app.py');
}

export function getPreferredVenvPython(projectRoot = getProjectRoot()): string {
    if (process.platform === 'win32') {
        return path.join(projectRoot, '.venv', 'Scripts', 'python.exe');
    }
    return path.join(projectRoot, '.venv', 'bin', 'python');
}

function canExecutePython(candidate: string): boolean {
    try {
        const probe = spawnSync(candidate, ['--version'], {
            encoding: 'utf-8',
            timeout: 5000,
        });
        return probe.status === 0;
    } catch {
        return false;
    }
}

function isLikelyPath(value: string): boolean {
    return value.includes(path.sep) || value.includes('/') || value.includes('\\');
}

export function resolvePythonPath(projectRoot = getProjectRoot()): string {
    const venvPython = getPreferredVenvPython(projectRoot);

    const envCandidates = [
        process.env.AUDIOBOOK_PYTHON,
        process.env.PYTHON,
    ].filter((value): value is string => Boolean(value && value.trim().length > 0));

    const candidates = [
        ...envCandidates,
        venvPython,
        'python3',
        'python',
    ];

    for (const candidate of candidates) {
        if (isLikelyPath(candidate) && !fs.existsSync(candidate)) {
            continue;
        }
        if (canExecutePython(candidate)) {
            return candidate;
        }
    }

    throw new Error(
        'Unable to find a working Python interpreter. Run ./setup.sh or set AUDIOBOOK_PYTHON.'
    );
}

export function resolvePythonRuntime(): PythonRuntime {
    const projectRoot = getProjectRoot();
    return {
        projectRoot,
        appPath: getAppPath(projectRoot),
        pythonPath: resolvePythonPath(projectRoot),
    };
}

export function getNullDevice(): string {
    return process.platform === 'win32' ? 'NUL' : '/dev/null';
}
