import { spawn } from 'child_process';
import { resolvePythonRuntime } from './python-runtime.js';

export interface CheckpointStatus {
    exists: boolean;
    valid: boolean;
    totalChunks?: number;
    completedChunks?: number;
    reason?: string; // Reason for invalid checkpoint
}

/**
 * Check for an existing checkpoint for the given input/output files.
 */
export function checkCheckpoint(
    inputPath: string,
    outputPath: string
): Promise<CheckpointStatus> {
    return new Promise((resolve, reject) => {
        const { projectRoot, appPath: pythonScript, pythonPath } = resolvePythonRuntime();

        const args = [
            pythonScript,
            '--input', inputPath,
            '--output', outputPath,
            '--check_checkpoint',
        ];

        const process = spawn(pythonPath, args, {
            cwd: projectRoot,
            env: {
                ...globalThis.process.env,
                PYTHONUNBUFFERED: '1',
            },
        });

        let stdout = '';
        let stderr = '';

        process.stdout.on('data', (data: Buffer) => {
            stdout += data.toString();
        });

        process.stderr.on('data', (data: Buffer) => {
            stderr += data.toString();
        });

        process.on('error', (err) => {
            reject(new Error(`Failed to check checkpoint: ${err.message}`));
        });

        process.on('close', (code) => {
            if (code === 0) {
                // Parse the checkpoint status from stdout
                const lines = stdout.split('\n');
                for (const line of lines) {
                    if (line === 'CHECKPOINT:NONE') {
                        resolve({ exists: false, valid: false });
                        return;
                    }
                    if (line.startsWith('CHECKPOINT:FOUND:')) {
                        const parts = line.slice(17).split(':');
                        if (parts.length >= 2) {
                            resolve({
                                exists: true,
                                valid: true,
                                totalChunks: parseInt(parts[0], 10),
                                completedChunks: parseInt(parts[1], 10),
                            });
                            return;
                        }
                    }
                    if (line.startsWith('CHECKPOINT:INVALID:')) {
                        resolve({
                            exists: true,
                            valid: false,
                            reason: line.slice(19),
                        });
                        return;
                    }
                }
                // No checkpoint info found
                resolve({ exists: false, valid: false });
            } else {
                reject(new Error(`Checkpoint check failed with code ${code}\n${stderr}`));
            }
        });
    });
}

/**
 * Delete a checkpoint directory for the given output file.
 */
export function deleteCheckpoint(outputPath: string): Promise<void> {
    return new Promise((resolve, reject) => {
        const checkpointDir = `${outputPath}.checkpoint`;
        import('fs').then(fs => {
            if (fs.existsSync(checkpointDir)) {
                fs.rmSync(checkpointDir, { recursive: true, force: true });
            }
            resolve();
        }).catch(reject);
    });
}
