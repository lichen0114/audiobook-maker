import { spawn } from 'child_process';

export function openFolder(folderPath: string): void {
    let command = '';
    let args: string[] = [];

    if (process.platform === 'darwin') {
        command = 'open';
        args = [folderPath];
    } else if (process.platform === 'win32') {
        command = 'cmd';
        args = ['/c', 'start', '', folderPath];
    } else {
        command = 'xdg-open';
        args = [folderPath];
    }

    const child = spawn(command, args, {
        detached: true,
        stdio: 'ignore',
    });
    child.unref();
}
