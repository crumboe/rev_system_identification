"""Test loading REVLibDriver.dll and probing its exported functions."""

import ctypes
import os
import re

DLL_DIR = os.path.join(os.path.dirname(__file__), "revlib_dlls")

def find_dll_imports():
    """Scan binary for .dll references to find missing deps."""
    dll_path = os.path.join(DLL_DIR, "REVLibDriver.dll")
    with open(dll_path, "rb") as f:
        data = f.read()
    dlls = set(re.findall(rb"([A-Za-z0-9_]+\.dll)", data))
    print("DLL references found in REVLibDriver.dll:")
    for d in sorted(dlls):
        print(f"  {d.decode()}")


def try_load():
    """Try loading REVLibDriver.dll with all deps."""
    os.add_dll_directory(DLL_DIR)

    # Load dependencies in order
    deps = ["wpiutil.dll", "wpiHal.dll", "wpinet.dll", "ntcore.dll", "wpimath.dll"]
    for dep in deps:
        path = os.path.join(DLL_DIR, dep)
        try:
            ctypes.CDLL(path)
            print(f"  Loaded {dep}")
        except Exception as e:
            print(f"  FAILED {dep}: {e}")

    # Try main DLL
    dll_path = os.path.join(DLL_DIR, "REVLibDriver.dll")
    try:
        dll = ctypes.CDLL(dll_path, winmode=0)
        print("\nREVLibDriver.dll loaded successfully!")
        return dll
    except Exception as e:
        print(f"\nLoading failed: {e}")
        return None


def probe_exports(dll):
    """Probe known function names from the REVLib-driver headers."""
    functions = [
        # From CANSparkDriver.h
        "c_Spark_Create",
        "c_Spark_Destroy",
        "c_Spark_SetParameter",
        "c_Spark_GetParameter",
        "c_Spark_PersistParameters",
        "c_Spark_SetpointCommand",
        "c_Spark_RegisterDeviceToHAL",
        "c_Spark_Scan",
        "c_Spark_Open",
        "c_Spark_Close",
        "c_Spark_GetFirmwareVersion",
        "c_Spark_SetInverted",
        "c_Spark_GetInverted",
        "c_Spark_SetIdleMode",
        "c_Spark_GetIdleMode",
        # From CANAPI maybe
        "c_Spark_CreateDirect",
        "c_REVLib_Init",
        "c_REVLib_Shutdown",
    ]

    print("\nExported functions:")
    found = []
    for fn in functions:
        try:
            addr = ctypes.cast(getattr(dll, fn), ctypes.c_void_p).value
            print(f"  {fn}: 0x{addr:X}")
            found.append(fn)
        except AttributeError:
            print(f"  {fn}: NOT FOUND")
    return found


if __name__ == "__main__":
    find_dll_imports()
    print()
    dll = try_load()
    if dll:
        probe_exports(dll)
