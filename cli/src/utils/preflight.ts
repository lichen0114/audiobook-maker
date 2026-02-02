import { execSync, spawnSync } from 'child_process';
import * as fs from 'fs';
import * as path from 'path';

export interface PreflightCheck {
    name: string;
    status: 'ok' | 'warning' | 'error';
    message: string;
    fix?: string;
}

export interface PreflightResult {
    passed: boolean;
    checks: PreflightCheck[];
}

/**
 * Get the project root directory (parent of cli/)
 */
function getProjectRoot(): string {
    return path.resolve(import.meta.dirname, '../../..');
}

/**
 * Check if FFmpeg is installed
 */
function checkFFmpeg(): PreflightCheck {
    try {
        execSync('ffmpeg -version', { stdio: 'pipe' });
        return {
            name: 'FFmpeg',
            status: 'ok',
            message: 'FFmpeg is installed',
        };
    } catch {
        return {
            name: 'FFmpeg',
            status: 'error',
            message: 'FFmpeg is not installed',
            fix: 'brew install ffmpeg',
        };
    }
}

/**
 * Check if Python virtual environment exists and has correct version
 */
function checkPythonVenv(): PreflightCheck {
    const projectRoot = getProjectRoot();
    const venvPython = path.join(projectRoot, '.venv', 'bin', 'python');

    if (!fs.existsSync(venvPython)) {
        return {
            name: 'Python venv',
            status: 'error',
            message: 'Python virtual environment not found',
            fix: './setup.sh',
        };
    }

    // Check Python version
    try {
        const result = spawnSync(venvPython, ['--version'], { encoding: 'utf-8' });
        if (result.status !== 0) {
            return {
                name: 'Python venv',
                status: 'error',
                message: 'Failed to get Python version',
                fix: './setup.sh',
            };
        }

        const version = result.stdout.trim().replace('Python ', '');
        const [major, minor] = version.split('.').map(Number);

        if (major !== 3 || minor < 10 || minor > 12) {
            return {
                name: 'Python venv',
                status: 'error',
                message: `Python ${version} found, but 3.10-3.12 is required`,
                fix: './setup.sh',
            };
        }

        return {
            name: 'Python venv',
            status: 'ok',
            message: `Python ${version}`,
        };
    } catch {
        return {
            name: 'Python venv',
            status: 'error',
            message: 'Failed to check Python version',
            fix: './setup.sh',
        };
    }
}

/**
 * Check if Python dependencies are installed (specifically kokoro)
 */
function checkPythonDeps(): PreflightCheck {
    const projectRoot = getProjectRoot();
    const venvPython = path.join(projectRoot, '.venv', 'bin', 'python');

    if (!fs.existsSync(venvPython)) {
        return {
            name: 'Python deps',
            status: 'error',
            message: 'Python venv not found',
            fix: './setup.sh',
        };
    }

    try {
        // Check if kokoro is importable
        const result = spawnSync(venvPython, ['-c', 'import kokoro'], {
            encoding: 'utf-8',
            timeout: 10000,
        });

        if (result.status !== 0) {
            return {
                name: 'Python deps',
                status: 'error',
                message: 'Kokoro TTS not installed',
                fix: 'source .venv/bin/activate && pip install -r requirements.txt',
            };
        }

        return {
            name: 'Python deps',
            status: 'ok',
            message: 'Kokoro TTS ready',
        };
    } catch {
        return {
            name: 'Python deps',
            status: 'error',
            message: 'Failed to check Python dependencies',
            fix: './setup.sh',
        };
    }
}

/**
 * Check if the app.py script exists
 */
function checkAppScript(): PreflightCheck {
    const projectRoot = getProjectRoot();
    const appPath = path.join(projectRoot, 'app.py');

    if (!fs.existsSync(appPath)) {
        return {
            name: 'App script',
            status: 'error',
            message: 'app.py not found',
            fix: 'Make sure you are running from the project directory',
        };
    }

    return {
        name: 'App script',
        status: 'ok',
        message: 'app.py found',
    };
}

/**
 * Run all preflight checks
 */
export function runPreflightChecks(): PreflightResult {
    const checks: PreflightCheck[] = [
        checkFFmpeg(),
        checkPythonVenv(),
        checkPythonDeps(),
        checkAppScript(),
    ];

    const passed = checks.every(
        (check) => check.status === 'ok' || check.status === 'warning'
    );

    return { passed, checks };
}

/**
 * Quick check - returns true if all critical dependencies are available
 * This is faster than runPreflightChecks() as it doesn't import Python modules
 */
export function quickCheck(): boolean {
    const projectRoot = getProjectRoot();
    const venvPython = path.join(projectRoot, '.venv', 'bin', 'python');
    const appPath = path.join(projectRoot, 'app.py');

    // Check FFmpeg
    try {
        execSync('which ffmpeg', { stdio: 'pipe' });
    } catch {
        return false;
    }

    // Check venv exists
    if (!fs.existsSync(venvPython)) {
        return false;
    }

    // Check app.py exists
    if (!fs.existsSync(appPath)) {
        return false;
    }

    return true;
}
