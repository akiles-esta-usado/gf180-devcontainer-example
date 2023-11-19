try:
    import ngspyce as ns
except ModuleNotFoundError:
    print("Ngspyce not found")
    exit()

from pathlib import Path
from pprint import pprint
import numpy as np

# == ENVIRONMENT SETTING == #

project_dir = Path("/headless") / ".xschem" / "simulations"
data_dir = Path(".data") / "ota"
img_dir = Path(".img") / "ota"

if not project_dir.exists():
    print("Project directory doesn't exist :(")
else:
    for thing in project_dir.iterdir():
        print(thing)

if not data_dir.exists():
    print("No data dir, creating...")
    data_dir.mkdir()

if not img_dir.exists():
    img_dir.mkdir()


# == NS INTERACTION HANDLERS == #


def ns_gf_store(device: str, attr: str):
    return f"save @m.x{device}.m0[{attr}]"


def ns_gf_retrieve(device: str, attr: str):
    return f"@m.x{device}.m0[{attr}]"


def print_keys_length(res: dict):
    for key in res.keys():
        print(f"{key: <40}: {len(res[key])} elements")


def ns_log(enable: bool):
    if enable:
        import logging

        logging.getLogger(ns.__name__).setLevel(logging.DEBUG)
    else:
        import logging

        logging.getLogger(ns.__name__).setLevel(logging.CRITICAL)


# == NUMPY AND MATPLOTLIB HANDLERS == #


def numpy_store_data(data: dict, filename: str):
    file = data_dir / filename
    try:
        np.savez(file, **data)
        if file.exists():
            print(f"Data stored in file {file}")
        else:
            print("Error while storing data")
    except Exception:
        print("Error while storing data")


def numpy_get_data(filename):
    _ = np.load(data_dir / filename)
    data = {key: _[key] for key in _}
    pprint(data.keys())
    return data


def plt_add_vsweep(ax, data: dict, title: str, ylabel: str):
    v_sweep = data["v-sweep"]
    for label, value in data.items():
        if label == "v-sweep":
            continue
        ax.plot(v_sweep, value, label=label)

    ax.set_title(title)
    ax.set_xlabel("v-sweep")
    ax.set_ylabel(ylabel)
    ax.grid()
    ax.legend()
    return ax


def plt_add_transient(ax, data: dict, title: str, ylabel: str):
    time = data["time"]
    for label, value in data.items():
        if label == "time":
            continue
        ax.plot(time, value, label=label)

    ax.set_title(title)
    ax.set_xlabel("time [t]")
    ax.set_ylabel(ylabel)
    ax.grid()
    ax.legend()
    return ax


def plt_add_psrr(ax, data: dict, title: str, ylabel: str):
    freq = data["freq"]
    for label, value in data.items():
        if label == "freq":
            continue
        ax.semilogx(freq, 20 * np.log10(np.abs(value)), label=label)

    ax.set_title(title)
    ax.set_xlabel("Frequency [Hz]")
    ax.set_ylabel(ylabel)
    ax.grid()
    ax.legend()
    return ax


def plt_add_bode(ax_gain, ax_phase, data, xmax=None):
    freq = data["freq"]
    for label, value in data.items():
        if label == "freq":
            continue
        ax_gain.semilogx(freq, 20 * np.log10(np.abs(value)), label=label)
        ax_phase.semilogx(freq, np.angle(value, True), label=label)

    ax_gain.axhline(0, color="black", linestyle="dashed")
    ax_phase.axhline(-180 + 60, color="black", linestyle="dashed")

    if xmax:
        ax_gain.set_xlim(min(freq), xmax)
    else:
        ax_gain.set_xlim(min(freq), max(freq))

    ax_gain.set_title("Bode Gain Diagram")
    ax_gain.grid()
    ax_gain.set_xlabel("Frequency [Hz]")
    ax_gain.set_ylabel("Gain [dB]")
    ax_gain.legend()
    ax_gain.margins(x=0)

    ax_phase.set_title("Bode Phase Diagram")
    ax_phase.grid()
    ax_phase.set_xlabel("Frequency [Hz]")
    ax_phase.set_ylabel("Phase [degrees]")
    ax_phase.legend()
    ax_phase.margins(x=0)
