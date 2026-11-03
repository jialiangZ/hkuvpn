//go:build windows

package main

import (
	"syscall"
	"unsafe"
)

var (
	kernel32 = syscall.NewLazyDLL("kernel32.dll")
	shell32  = syscall.NewLazyDLL("shell32.dll")
	user32   = syscall.NewLazyDLL("user32.dll")

	procOpenProcess         = kernel32.NewProc("OpenProcess")
	procGetExitCodeProcess  = kernel32.NewProc("GetExitCodeProcess")
	procCloseHandle         = kernel32.NewProc("CloseHandle")
	procMultiByteToWideChar = kernel32.NewProc("MultiByteToWideChar")
	procShellExecuteW       = shell32.NewProc("ShellExecuteW")
	procMessageBoxW         = user32.NewProc("MessageBoxW")
)

const (
	processQueryLimitedInformation = 0x1000
	stillActive                    = 259
	swHide                         = 0
	mbOKIconError                  = 0x00000010
)

func processAlive(pid int) bool {
	h, _, _ := procOpenProcess.Call(processQueryLimitedInformation, 0, uintptr(uint32(pid)))
	if h == 0 {
		return false
	}
	defer procCloseHandle.Call(h)
	var code uint32
	ok, _, _ := procGetExitCodeProcess.Call(h, uintptr(unsafe.Pointer(&code)))
	return ok != 0 && code == stillActive
}

func shellExecute(exe, params, verb string, show int) int {
	exePtr, _ := syscall.UTF16PtrFromString(exe)
	paramsPtr, _ := syscall.UTF16PtrFromString(params)
	var verbPtr *uint16
	if verb != "" {
		verbPtr, _ = syscall.UTF16PtrFromString(verb)
	}
	ret, _, _ := procShellExecuteW.Call(
		0,
		uintptr(unsafe.Pointer(verbPtr)),
		uintptr(unsafe.Pointer(exePtr)),
		uintptr(unsafe.Pointer(paramsPtr)),
		0,
		uintptr(show),
	)
	return int(ret)
}

func shellExecuteRunAs(exe, params string) (int, error) {
	code := shellExecute(exe, params, "runas", swHide)
	if code <= 32 {
		return code, syscall.Errno(code)
	}
	return code, nil
}

func shellExecuteHidden(exe, params string) {
	shellExecute(exe, params, "", swHide)
}

// acpDecode turns the worker's ANSI text (the system code page, e.g. GBK on
// Chinese Windows) into UTF-8 for the UI.
func acpDecode(b []byte) string {
	if len(b) == 0 {
		return ""
	}
	const cpACP = 0
	n, _, _ := procMultiByteToWideChar.Call(
		cpACP, 0,
		uintptr(unsafe.Pointer(&b[0])), uintptr(len(b)),
		0, 0,
	)
	if n == 0 {
		return string(b)
	}
	buf := make([]uint16, n)
	procMultiByteToWideChar.Call(
		cpACP, 0,
		uintptr(unsafe.Pointer(&b[0])), uintptr(len(b)),
		uintptr(unsafe.Pointer(&buf[0])), n,
	)
	return syscall.UTF16ToString(buf)
}

// showMessageBox puts a modal message on screen: the app has no console
// window of its own to print to.
func showMessageBox(title, msg string) {
	titlePtr, _ := syscall.UTF16PtrFromString(title)
	msgPtr, _ := syscall.UTF16PtrFromString(msg)
	procMessageBoxW.Call(0,
		uintptr(unsafe.Pointer(msgPtr)),
		uintptr(unsafe.Pointer(titlePtr)),
		mbOKIconError)
}
