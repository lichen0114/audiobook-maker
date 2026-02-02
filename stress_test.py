import torch

# Create a massive matrix to force the GPU to work hard
device = torch.device("mps")
x = torch.randn(5000, 5000, device=device)
y = torch.randn(5000, 5000, device=device)

print("Running stress test... Check Activity Monitor now.")
while True:
    # Big matrix multiplication = High Compute, Low Overhead
    z = torch.matmul(x, y)
