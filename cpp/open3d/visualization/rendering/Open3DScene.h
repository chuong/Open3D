// ----------------------------------------------------------------------------
// -                        Open3D: www.open3d.org                            -
// ----------------------------------------------------------------------------
// The MIT License (MIT)
//
// Copyright (c) 2018 www.open3d.org
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
// FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
// IN THE SOFTWARE.
// ----------------------------------------------------------------------------

#pragma once

#include "open3d/geometry/BoundingVolume.h"
#include "open3d/visualization/rendering/Renderer.h"

#include <map>

namespace open3d {

namespace geometry {
class Geometry3D;
}  // namespace geometry

namespace visualization {
namespace rendering {

class Camera;
struct Material;

class Open3DScene {
public:
    Open3DScene(Renderer& renderer);
    ~Open3DScene();

    ViewHandle CreateView();
    void DestroyView(ViewHandle view);
    View* GetView(ViewHandle view) const;

    void ShowSkybox(bool enable);
    void ShowAxes(bool enable);

    void ClearGeometry();
    /// Adds a geometry with the specified name. Default visible is true.
    void AddGeometry(const std::string& name,
                     std::shared_ptr<const geometry::Geometry3D> geom,
                     const Material& mat,
                     bool add_downsampled_copy_for_fast_rendering = true);
    void RemoveGeometry(const std::string& name);
    /// Shows or hides the geometry with the specified name.
    void ShowGeometry(const std::string& name, bool show);
    /// Updates all geometries to use this material
    void UpdateMaterial(const Material& mat);

    const geometry::AxisAlignedBoundingBox& GetBoundingBox() { return bounds_; }

    enum class LOD {
        HIGH_DETAIL,  // used when rendering time is not as important
        FAST,         // used when rendering time is important, like rotating
    };
    void SetLOD(LOD lod);
    LOD GetLOD() const;

    Scene* GetScene() const;
    Camera* GetCamera() const;

private:
    struct GeometryData {
        std::string name;
        std::string fast_name;
        bool visible;

        GeometryData() : visible(false) {}  // for STL containers
        GeometryData(const std::string& n, const std::string& fast)
            : name(n), fast_name(fast), visible(true)
        {}
    };

    void SetGeometryToLOD(const GeometryData&, LOD lod);
    
private:
    Renderer& renderer_;
    SceneHandle scene_;
    ViewHandle view_;

    LOD lod_ = LOD::HIGH_DETAIL;
    std::map<std::string, GeometryData> geometries_;  // name -> data
    geometry::AxisAlignedBoundingBox bounds_;
};

}  // namespace rendering
}  // namespace visualization
}  // namespace open3d
