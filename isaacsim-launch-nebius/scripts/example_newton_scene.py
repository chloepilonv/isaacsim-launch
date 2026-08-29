"""Run inside the container:
     sudo docker exec -it isim-isaac-sim-1 ./python.sh /workspace/scripts/example_newton_scene.py

Opens a .usd from the synced workspace and puts it on the Newton backend.
"""
from isaacsim import SimulationApp

simulation_app = SimulationApp({"headless": True})

from isaacsim.core.api import World                       # noqa: E402
from isaacsim.core.simulation_manager import SimulationManager  # noqa: E402
from isaacsim.core.utils.stage import open_stage          # noqa: E402

print("available physics engines:", SimulationManager.get_available_physics_engines(verbose=True))

# Must happen BEFORE the simulation starts.
if SimulationManager.switch_physics_engine("newton"):
    print("physics backend -> newton")
else:
    print("newton unavailable, staying on physx "
          "(relaunch the stack with PHYSICS_BACKEND=newton)")

open_stage("/workspace/assets/my_scene.usd")   # <- your synced asset

world = World(stage_units_in_meters=1.0)
world.reset()
for _ in range(600):
    world.step(render=True)

simulation_app.close()
