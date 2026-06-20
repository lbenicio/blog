---
title: "Building A Simple Ray Tracer: Bvh Acceleration, Anti Aliasing, And Path Tracing"
description: "A comprehensive technical exploration of building a simple ray tracer: bvh acceleration, anti aliasing, and path tracing, covering key concepts, practical implementations, and real-world applications."
date: "2025-09-20"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "static/images/blog/Building-A-Simple-Ray-Tracer-Bvh-Acceleration,-Anti-Aliasing,-And-Path-Tracing.png"
coverAlt: "Technical visualization representing building a simple ray tracer: bvh acceleration, anti aliasing, and path tracing"
---

Here is the expanded blog post, taking the original kernel of an idea and building it into a comprehensive, deep-dive technical article. The goal is to explore not just _how_ ray tracing works, but the entire philosophical, mathematical, and engineering war it has fought against the conventional rasterized pipeline.

---

# The Pinhole Problem: From a Single Point to a World of Light

We’ve all seen the image. A perfect, crystalline sphere of glass rests on a checkered plane. Light bends and caresses its surface, throwing a sharp, colored shadow to the right. The reflections in the sphere are slightly warped, a miniature universe contained within a transparent orb. It’s the iconic, almost cliché, test scene of computer graphics. But look closer. Zoom into the edge of that shadow. See the jagged, stair-step pattern crawling along the border? Watch as the glossy reflection on the sphere flickers, breaking into harsh, discrete patches of color. This isn't a flaw in the artist's vision; it is the screaming, visible cost of a fundamental compromise.

This image, beautiful as it may be, is a liar. It pretends the world is built from discrete pixels, that light travels in neat, tidy paths, and that geometry can be approximated without consequence. For decades, the real-time graphics we saw in games and interactive applications were built on this lie, a magnificent fraud of rasterization and shaders that tricked the eye with smoke, mirrors, and a mountain of clever approximations. But a different kind of lie has always existed, a more beautiful, more _truthful_ one: the ray-traced image.

The idea is deceptively simple. Instead of projecting polygons onto a screen, you invert the process of photography. You start from the viewer’s eye (or the camera), and for every pixel on the screen, you fire a mathematical ray into a digital scene. You trace that ray as it bounces off surfaces, through materials, from light sources. You follow the photon backwards. In doing so, you can calculate the exact color, radiance, and illumination of that single point in space with near-physical accuracy. No tricks. No lies. Just geometry and the elegant laws of optics.

It sounds like magic, and in a sense, it is. It is the magic that gave us the photorealistic, simulation-level visual effects in films like _Toy Story_ and _Avatar_. For twenty years, however, that magic was reserved for the offline render farm. A single frame of _Finding Nemo_ might take hours to render. A single frame of a video game had only 16.6 milliseconds. The battle to bring ray tracing into the real-time domain is the story of modern computer graphics, a war fought with algorithms, silicon, and a stubborn refusal to accept the jagged edge of the lie.

## Chapter 1: The Camera Obscura and the Mathematical Photon

To understand the pinhole problem, we must first go back to the ancient world. The _camera obscura_ (Latin for "dark chamber") was a simple device: a dark room with a tiny hole in one wall. Light from the outside would pass through that hole and project an inverted image of the scene onto the opposite wall. This was the first camera.

The pinhole acts as a perfect, albeit dim, lens. Any single point on the wall can only receive light from a single, specific direction in the outside world. The smaller the hole, the sharper the image—but the dimmer it becomes. This is nature's brute-force ray tracer.

In computer graphics, we simulate this. We have a _virtual_ pinhole camera. We define a plane of pixels (the film) and a single point in space (the aperture). The "problem" is geometric: For each pixel center, we can draw a line from that pixel through the aperture and into the scene. That line is our ray.

**The Ray Equation:**
A ray is defined parametrically:
\[ P(t) = O + t \cdot D \]
Where:

- \( O \) is the origin (the aperture or the pixel).
- \( D \) is the direction unit vector (pointing from the pixel through the aperture).
- \( t \) is a scalar distance along the ray.

The "problem" becomes a pure computational challenge: Find the smallest positive \( t \) at which this ray intersects an object in the scene. That intersection point is what the pixel "sees." The color of that point determines the color of the pixel.

This is elegant. It solves the **visibility problem** (what is visible?) instantly. No Z-buffer, no depth sorting, no overdraw. You just find the first hit. This simplicity is the siren song of ray tracing. But this simplicity hides a brutal computational reality: you have to test every ray against every triangle in the scene. If you have a scene with one million triangles and a 1920x1080 screen, you are looking at roughly 2 billion ray-triangle intersection tests _per frame_. That number alone explains why, for 30 years, real-time graphics said, "Thanks, but no thanks."

## Chapter 2: The Lie of Rasterization (and Why We Loved It)

Instead of tracing photons, rasterization took a shortcut. It projected the geometry onto the screen. It solved the "where is this triangle?" problem rather than the "what does this pixel see?" problem.

**The Rasterization Pipeline (Simplified):**

1.  **Vertex Processing:** Transform 3D triangle vertices into 2D screen space.
2.  **Rasterization:** Determine which pixels on the screen are covered by the 2D triangle. This generates _fragments_ (potential pixels).
3.  **Fragment Processing:** For each fragment, interpolate depth, normals, and texture coordinates. Run a shader to calculate the color.
4.  **Output Merging:** Use the Z-buffer to resolve visibility. The fragment with the smallest depth wins.

Rasterization is incredibly fast because it is _coherent_. Triangles are processed in order. Memory access is sequential. Hardware can be built around this (the GPU is, at its core, a massively parallel rasterization engine).

However, rasterization is geometrically stupid. It knows about triangles, but it knows nothing about light. Every visual effect beyond the most basic diffuse shading is a clever hack:

- **Shadows:** Rasterization doesn't do shadows. We use _shadow maps_: Render the scene from the light's perspective, store the depth, and then compare. This works, but it suffers from aliasing (jagged shadow edges), perspective aliasing (blocky shadows far away), and peter-panning (shadow that doesn't touch the object). You can "soak" the shadow map to soften the edges, but it is still a lie.
- **Reflections:** Rasterization doesn't reflect. We use _environment maps_ or _screen-space reflections_ (SSR). SSR is a horrifying hack: it reflects only what is already on the screen. If an object is off-screen or behind the camera, it doesn't exist in the reflection. This is why you often see reflections "bleeding" or disappearing in modern AAA games.
- **Global Illumination (GI):** The most expensive hack of all. To simulate light bouncing off walls and coloring a ceiling, engines use _lightmaps_ (pre-calculated static lighting), _voxel-based_ GI (tracing into a low-resolution voxel grid), or _screen-space ambient occlusion_ (SSAO) which is a cheap, inaccurate way to approximate contact shadows.

These hacks are the architectural essence of 1999-2018 game graphics. They are clever, performant, and entirely fake. A good artist can make them look incredible. A great artist can make them look real. But the illusion breaks under scrutiny. A mirror that doesn't reflect a moving character perfectly is a dead giveaway. A shadow that looks like a "blob" instead of a sharp, colored projection is a dead giveaway.

## Chapter 3: The Whitted Breakthrough: Tracing the Light Backwards

In 1979, Turner Whitted published a paper that changed the course of computer graphics: "An Improved Illumination Model for Shaded Display." He introduced the concept of **recursive ray tracing**.

The idea was a perfect synthesis of physical optics and computational efficiency. You don't trace rays from the light (forward tracing) because 99.999% of those rays miss the camera. Instead, you trace from the camera _backwards_. You send a primary ray into the scene. When it hits a surface, you ask: "What is illuminating this point?"

To answer this, you send more rays:

1.  **Shadow Rays:** From the hit point to each light source. If a ray hits another object before reaching the light, the point is in shadow. This provides perfect, hard shadows, no hacks required.
2.  **Reflection Rays:** If the surface is reflective (like a mirror or chrome), you calculate the reflection direction and recursively trace a new ray from the hit point in that direction. The color returned by that secondary ray is the color of the reflection.
3.  **Refraction Rays:** If the surface is transparent (like glass), you calculate the refraction direction using Snell's Law (\( n_1 \sin(\theta_1) = n_2 \sin(\theta_2) \)). You trace a new ray into the object, accounting for the bending of light.

This recursion creates a tree of rays. A primary ray hits a mirror that reflects into a glass ball that refracts onto a floor, and so on. The final color of the pixel is the aggregate of all these rays.

**The Core Algorithm (Pseudocode):**

```c
Color trace(Ray ray, int depth) {
    if (depth > MAX_DEPTH) return BLACK;

    HitRecord rec = scene->hit(ray);
    if (!rec.hit) return BACKGROUND_COLOR;

    Color color = rec.material->emittance; // If light source

    // Direct Illumination (Shadow Rays)
    for (Light* light : scene->lights) {
        Vec3 light_dir = normalize(light->position - rec.point);
        Ray shadow_ray(rec.point + epsilon * light_dir, light_dir);
        if (!scene->hit(shadow_ray)) {
            color += rec.material->diffuse * light->intensity * dot(rec.normal, light_dir);
        }
    }

    // Reflection
    if (rec.material->reflectance > 0) {
        Vec3 ref_dir = reflect(ray.direction, rec.normal);
        Ray ref_ray(rec.point + epsilon * ref_dir, ref_dir);
        color += rec.material->reflectance * trace(ref_ray, depth+1);
    }

    // Refraction
    if (rec.material->transparency > 0) {
        // Snell's law, handle total internal reflection
        Vec3 refr_dir = refract(ray.direction, rec.normal, rec.material->ior);
        Ray refr_ray(rec.point - epsilon * refr_dir, refr_dir);
        color += rec.material->transparency * trace(refr_ray, depth+1);
    }

    return color;
}
```

This was a revolution. It gave perfect reflections, perfect shadows, perfect refractions. The hit movie _Toy Story_ (1995) was rendered using a full, brute-force, non-real-time ray tracer called **REYES** (Renders Everything You Ever Saw). Every frame, every shadow, every reflection was physically accurate. That’s why _Toy Story_ still looks artistically valid 30 years later. The geometry is simple, but the _light_ is real.

## Chapter 4: The Rendering Equation and the Path to Noise

Whitted ray tracing was brilliant for mirrors and glass, but it was terrible for _glossy_ surfaces and soft lighting. A perfect mirror only needs one reflection ray. A glossy, brushed metal surface needs _hundreds_ of rays to capture the statistical distribution of microfacets.

In 1986, James Kajiya published the **Rendering Equation**, the holy grail of physically-based rendering:
\[ L*o(p, \omega_o) = L_e(p, \omega_o) + \int*{\Omega} f_r(p, \omega_i, \omega_o) L_i(p, \omega_i) (\omega_i \cdot n) d\omega_i \]

This looks terrifying, but the meaning is simple:

- \( L_o \) = The light leaving a point \( p \) in direction \( \omega_o \) (the color you see).
- \( L*e \) = The light \_emitted* by that point (if it's a light source).
- \( f_r \) = The BRDF (Bidirectional Reflectance Distribution Function) – how the surface scatters light. Is it a mirror? Is it matte? Is it glossy?
- \( L*i \) = The light \_incoming* to point \( p \) from direction \( \omega_i \).
- \( \omega_i \cdot n \) = The cosine falloff (Lambert's law).
- \( \int\_{\Omega} \) = An integral over the entire hemisphere above the point.

The rendering equation is an **integral over an infinite set of directions**. You cannot solve this exactly. You have to estimate it using **Monte Carlo integration**.

**Monte Carlo Integration:**
Instead of summing an infinite number of rays, you sum a finite, random sample. For example, to approximate the integral over the hemisphere, you fire \( N \) random rays. The average of these \( N \) rays, divided by the probability density of choosing each direction, gives an estimate of the true integral.

This is where **noise** enters the picture. With only a few random samples, the estimate is incredibly noisy. It looks like static on a TV. As you increase the number of samples (rays per pixel), the noise decreases. The rate of convergence is slow: to halve the noise, you need 4x the samples.

This "convergence noise" is the fundamental barrier to real-time ray tracing. A film renderer might use 10,000 samples per pixel (spp). That is 10,000 ray bounces per pixel. A real-time game, in 2018, could barely afford 1 sample per pixel (1 spp).

## Chapter 5: The Hardware Revolution: How RT Cores Broke the Dam

For decades, the software was ready, but the hardware was not. The fundamental problem was the **ray-triangle intersection test**. A generic GPU, optimized for the coherent memory access of rasterization, was terrible at this. A ray can hit any triangle in the scene. Memory access is random, incoherent, and unpredictable. This is the death knell for traditional SIMD (Single Instruction, Multiple Data) GPU architectures.

The solution came from **NVIDIA's RT Cores**, introduced in the Turing architecture (2018). RT Cores are dedicated, fixed-function hardware accelerators for the **Bounding Volume Hierarchy (BVH) traversal**.

**The BVH:**
A BVH is a tree structure. The root node is a large box that contains the entire scene. This box is divided into two smaller sub-boxes (usually by splitting the longest axis). This continues recursively until each leaf node contains a small number of triangles (often just 1 or 2).

To test a ray against a BVH:

1.  Start at the root. Test if the ray hits the root box. If not, the ray misses everything.
2.  If it hits, test the two child boxes. Traverse the nodes in order of intersection distance (closest first).
3.  Recurse down the tree until you hit a leaf node.
4.  Test the ray against the 1-2 triangles in the leaf node. This is a simple, fast geometric test (often using the Moller-Trumbore algorithm).
5.  You now have a candidate intersection. But you must continue traversing the other branches of the tree, because there may be an even closer triangle in a different box.

This is a tree traversal. It is branchy, unpredictable, and memory-intensive. RT Cores don't just speed this up; they _specialize_ in it. They can walk the BVH tree in hardware, returning the closest hit in a fixed, predictable latency. This frees the shader cores to do what they do best: compute the color, the material, the BRDF, the lighting.

The result was a generational leap. A GPU with RT Cores could do a ray-traced shadow or reflection at near-real-time frame rates. It wasn't full path tracing (1,000 samples per pixel) yet, but it was enough to replace the hacks.

## Chapter 6: The Real-Time Reality: Denoising and the 1 Sample Lie

So we have hardware that can cast 1-2 rays per pixel. We have the rendering equation that needs 1,000+ rays per pixel. How do we bridge this gap? The answer is **denoising**.

A 1 spp render is pure noise. It looks like static. But the _information_ is there. It's just hidden in the noise. Denoising algorithms use the spatial and temporal information of the image to reconstruct a clean image from a noisy one.

**Spatial Denoising:**

- Look at a noisy pixel. Look at its neighbors.
- Use the world-space positions, normals, and albedo (material color) of those neighbor pixels to define a "reconstruction kernel."
- If a neighbor has a similar normal and is at a similar depth, it probably belongs to the same surface. Average its color with the target pixel.
- This is essentially a smart, edge-aware blur.

**Temporal Denoising (Temporal Anti-Aliasing - TAA):**

- This is the secret sauce. For the current frame, you take the noisy 1 spp render.
- You compare it to the _previous_ frame's clean, denoised result.
- You reproject each pixel from the previous frame into the current frame using motion vectors (the velocity of the object).
- You accumulate the new data over many frames. Over 16 frames, you effectively get a 16 spp result.
- This is called **temporal accumulation**.

The result is shocking. A 1 spp render, accumulated over 16-32 frames, can look almost perfectly converged. The noise is gone. The reflection is solid. The shadow is soft.

**The Trade-off: Ghosting and Lag:**
Temporal denoising has a fatal flaw: **ghosting**. When a camera moves rapidly or an object moves quickly, the previous frame's data is now "wrong" for the current frame's position. The accumulation can leave behind a ghostly trail of the old frame.

To fix this, denoisers use **history rejection**: if the motion vectors are large, or if the new sample is very different from the old sample (Temporal Variance Guided Filtering), the old sample is discarded. But if you discard too aggressively, you get noise. This is the delicate, ever-present balancing act of modern real-time ray tracing.

## Chapter 7: The Modern Pipeline: A Hybrid Marriage

The wildest truth of modern game graphics is that _we don't fully ray trace everything_. We have a hybrid pipeline that uses the best of both worlds.

**The Hybrid Rasterization + Ray Tracing Pipeline:**

1.  **Rasterize the G-Buffer:** The traditional rasterization pipeline is still used to render the primary view. It outputs a G-Buffer containing depth, normals, albedo, and roughness for every visible pixel. This is incredibly fast.
2.  **Cast Primary Rays for Shadows:** Instead of shadow maps, we send a single, sharp shadow ray from each visible point to the main directional light. We use the G-Buffer to know exactly where "the visible point" is. This gives perfect, pixel-level shadow resolution. We can then use a denoiser to soften the shadow.
3.  **Cast Reflection Rays:** For glossy materials, we send a small number of reflection rays (1-4 rays per pixel). We trace them into the BVH. This gives us true reflections of the geometry, including objects off-screen. The result is noisy, so we denoise it heavily.
4.  **Cast Light Bounce Rays (GI):** This is the most expensive step. We send a few randomly oriented rays from the visible point into the scene. We see what they hit. This gives us an estimate of indirect light. This is aggregated over frames to build a stable, real-time global illumination solution.
5.  **Combine and Shade:** The final pixel color is a combination of the rasterized direct lighting, the ray-traced shadows, the ray-traced reflections, and the ray-traced indirect light. The result is a scene that is physically plausible in a way that hacks never were.

**Concrete Example: _Cyberpunk 2077_ (Path Tracing Overdrive Mode):**
In 2023, _Cyberpunk 2077_ introduced a "Path Tracing" mode. This is not the hybrid approach. This is full, brute-force path tracing in real-time. For every pixel, they cast a primary ray. That ray bounces randomly through the scene, building a full path. They use 1-2 samples per pixel, and then rely on a proprietary temporal denoiser that uses neural networks. The result is a game that looks like a movie. The reflections in puddles are perfect. The light bouncing from a red neon sign onto a character's face is accurate. The shadows are soft and colored.

It requires an expensive GPU (RTX 4090) and uses technologies like DLSS 3.5 (Deep Learning Super Sampling) to upscale from a lower resolution, further reducing the ray count. It is still not cheap, but it is _usable_. A decade ago, this was science fiction.

## Chapter 8: The Future: Beyond Light

The pinhole problem is not just about light. It is about data.

**The Ray-Query Revolution:**
The latest GPUs allow shaders to issue "ray queries" at any time. This means a shader can ask: "Is there an object between point A and point B?" This has applications far beyond graphics. Game physics engines can use ray queries for accurate line-of-sight checks, sound occlusion (how much sound travels around a corner?), or AI visibility. This is a computational model that unifies rendering, physics, and AI.

**Signed Distance Fields (SDFs):**
Traditional ray tracing uses triangles. But triangles are inefficient for curves and surfaces. Signed Distance Fields represent geometry as a function: \( f(x, y, z) \) returns the distance to the nearest surface. Inside the object, the distance is negative.

Ray tracing against an SDF is done via **sphere tracing** or **raymarching**. You step along the ray by the distance to the nearest surface. This is incredibly efficient for procedural geometry, fluid simulations, and volumetric effects (clouds, smoke). The future of ray tracing will likely be a hybrid of triangle-BVH for solid objects and SDF raymarching for volumetrics.

**Neural Rendering and the Death of the Shader?**
The shader is a human-written program that calculates material properties. But neural rendering is beginning to show that a neural network can _learn_ the BRDF of a material from data. This is the **NeRF** (Neural Radiance Field) revolution. Instead of tracing rays to calculate light transport, you train a neural network to memorize the light field of a scene. Then, to render a new view, you simply query the network.

This is incredibly expensive to train, but incredibly cheap to query. It is currently used for static objects (like a scanned car) but research is pushing it toward dynamic, real-time scenes. The ultimate future of the pinhole problem might be that we no longer simulate light at all. We just _learn_ it.

## Conclusion: The Cost of the Truth

The pinhole problem is solved. Not completely, not universally, but solved. We can now, on consumer hardware, simulate the physics of light in real time. We can trace a photon backward from the camera, bounce it through a digital world, and compute a color that is physically accurate.

The cost is enormous. A ray-traced frame on an RTX 4090 consumes 300-400 watts of power and generates immense heat. It requires dedicated silicon (RT Cores, Tensor Cores for denoising), complex temporal filtering, and vast amounts of memory bandwidth. The "simple" idea of a pinhole and a math equation has required the building of the most complex computational devices humanity has ever created.

But the result is worth it. We have stopped lying to ourselves. The jagged shadow is gone. The reflection in the sphere is no longer a flickering hack, but a true image of the world. The light that travels through the digital glass obeys the same laws as the light that travels through the window of your room.

The world is not made of pixels, and the pinhole problem reminds us that our representations of reality will always be approximations. But by staring into that single point of light, by asking the question "Where did you come from?" and following the answer back through the chain of bounces, we have built a better approximation. We have built a window into a world that never was, but feels more real than any vector or rasterized polygon ever could.

The light is the truth. And finally, we have the hardware to tell it.
